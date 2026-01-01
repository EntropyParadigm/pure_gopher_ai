defmodule PureGopherAi.IpReputation do
  @moduledoc """
  IP reputation scoring system.

  Tracks IP behavior over time and adjusts risk scores based on:
  - Failed authentication attempts
  - Rate limit violations
  - Content moderation blocks
  - Successful actions (positive reputation)

  Higher scores = higher risk (0-100).
  Default score for new IPs: 25
  """

  use GenServer
  require Logger

  @table :ip_reputation
  @default_score 25
  @max_score 100
  @min_score 0

  # Score adjustments
  @auth_failure_penalty 5
  @rate_limit_penalty 10
  @content_block_penalty 15
  @spam_penalty 20
  @successful_auth_bonus -2
  @successful_post_bonus -1

  # Decay settings (scores trend toward default over time)
  @decay_interval_ms 60 * 60 * 1000  # 1 hour
  @decay_amount 2

  # Thresholds
  @suspicious_threshold 50
  @high_risk_threshold 75
  @auto_block_threshold 90

  # Data persistence
  @dets_file "ip_reputation.dets"
  @cleanup_interval_ms 24 * 60 * 60 * 1000  # Daily
  @max_age_days 30

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the reputation score for an IP.
  Returns a score from 0-100 (higher = more risky).
  """
  def get_score(ip) do
    GenServer.call(__MODULE__, {:get_score, format_ip(ip)})
  end

  @doc """
  Gets the risk level for an IP.
  Returns :normal, :suspicious, :high_risk, or :blocked.
  """
  def get_risk_level(ip) do
    score = get_score(ip)

    cond do
      score >= @auto_block_threshold -> :blocked
      score >= @high_risk_threshold -> :high_risk
      score >= @suspicious_threshold -> :suspicious
      true -> :normal
    end
  end

  @doc """
  Checks if an IP should be automatically blocked.
  """
  def should_block?(ip), do: get_risk_level(ip) == :blocked

  @doc """
  Checks if an IP is suspicious (requires extra validation like CAPTCHA).
  """
  def is_suspicious?(ip), do: get_risk_level(ip) in [:suspicious, :high_risk, :blocked]

  @doc """
  Records a failed authentication attempt.
  """
  def record_auth_failure(ip) do
    GenServer.cast(__MODULE__, {:adjust, format_ip(ip), @auth_failure_penalty, :auth_failure})
  end

  @doc """
  Records a successful authentication.
  """
  def record_auth_success(ip) do
    GenServer.cast(__MODULE__, {:adjust, format_ip(ip), @successful_auth_bonus, :auth_success})
  end

  @doc """
  Records a rate limit violation.
  """
  def record_rate_limit(ip) do
    GenServer.cast(__MODULE__, {:adjust, format_ip(ip), @rate_limit_penalty, :rate_limit})
  end

  @doc """
  Records content being blocked by moderation.
  """
  def record_content_block(ip) do
    GenServer.cast(__MODULE__, {:adjust, format_ip(ip), @content_block_penalty, :content_block})
  end

  @doc """
  Records spam-like behavior.
  """
  def record_spam(ip) do
    GenServer.cast(__MODULE__, {:adjust, format_ip(ip), @spam_penalty, :spam})
  end

  @doc """
  Records a successful content post.
  """
  def record_successful_post(ip) do
    GenServer.cast(__MODULE__, {:adjust, format_ip(ip), @successful_post_bonus, :successful_post})
  end

  @doc """
  Manually adjusts an IP's score (admin action).
  """
  def adjust_score(ip, amount, reason \\ :admin_adjustment) do
    GenServer.cast(__MODULE__, {:adjust, format_ip(ip), amount, reason})
  end

  @doc """
  Resets an IP's score to default.
  """
  def reset_score(ip) do
    GenServer.cast(__MODULE__, {:reset, format_ip(ip)})
  end

  @doc """
  Gets detailed reputation info for an IP.
  """
  def get_info(ip) do
    GenServer.call(__MODULE__, {:get_info, format_ip(ip)})
  end

  @doc """
  Lists IPs above a certain risk threshold.
  """
  def list_risky(threshold \\ @suspicious_threshold) do
    GenServer.call(__MODULE__, {:list_risky, threshold})
  end

  @doc """
  Gets system statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Application.get_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
    dets_path = Path.join([Path.expand(data_dir), @dets_file]) |> String.to_charlist()

    File.mkdir_p!(Path.dirname(to_string(dets_path)))

    {:ok, _} = :dets.open_file(@table, [
      file: dets_path,
      type: :set,
      auto_save: 60_000
    ])

    # Schedule decay and cleanup
    schedule_decay()
    schedule_cleanup()

    Logger.info("[IpReputation] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get_score, ip}, _from, state) do
    score = case :dets.lookup(@table, ip) do
      [{^ip, data}] -> data.score
      [] -> @default_score
    end

    {:reply, score, state}
  end

  @impl true
  def handle_call({:get_info, ip}, _from, state) do
    info = case :dets.lookup(@table, ip) do
      [{^ip, data}] ->
        Map.merge(data, %{
          risk_level: calculate_risk_level(data.score),
          ip: ip
        })
      [] ->
        %{
          ip: ip,
          score: @default_score,
          risk_level: :normal,
          events: [],
          created_at: nil,
          updated_at: nil
        }
    end

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_call({:list_risky, threshold}, _from, state) do
    risky = :dets.foldl(fn
      {ip, %{score: score} = data}, acc when score >= threshold ->
        [{ip, data} | acc]
      _, acc ->
        acc
    end, [], @table)

    sorted = Enum.sort_by(risky, fn {_, d} -> d.score end, :desc)
    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = :dets.foldl(fn {_ip, data}, acc ->
      level = calculate_risk_level(data.score)
      acc
      |> Map.update(:total, 1, & &1 + 1)
      |> Map.update(level, 1, & &1 + 1)
      |> Map.update(:avg_score, data.score, fn avg -> (avg + data.score) / 2 end)
    end, %{total: 0, avg_score: 0}, @table)

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:adjust, ip, amount, reason}, state) do
    now = DateTime.utc_now()

    updated = case :dets.lookup(@table, ip) do
      [{^ip, data}] ->
        new_score = clamp(data.score + amount, @min_score, @max_score)
        event = %{type: reason, amount: amount, timestamp: now}
        events = [event | Enum.take(data.events, 49)]  # Keep last 50 events

        %{data | score: new_score, events: events, updated_at: now}

      [] ->
        new_score = clamp(@default_score + amount, @min_score, @max_score)
        %{
          score: new_score,
          events: [%{type: reason, amount: amount, timestamp: now}],
          created_at: now,
          updated_at: now
        }
    end

    :dets.insert(@table, {ip, updated})

    # Log high-risk adjustments
    if updated.score >= @high_risk_threshold do
      Logger.warning("[IpReputation] High risk IP: #{ip} (score: #{updated.score})")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:reset, ip}, state) do
    :dets.delete(@table, ip)
    {:noreply, state}
  end

  @impl true
  def handle_info(:decay, state) do
    decay_scores()
    schedule_decay()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # Private functions

  defp format_ip(ip) when is_tuple(ip) do
    case ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} ->
        "#{Integer.to_string(a, 16)}:#{Integer.to_string(b, 16)}:" <>
        "#{Integer.to_string(c, 16)}:#{Integer.to_string(d, 16)}:" <>
        "#{Integer.to_string(e, 16)}:#{Integer.to_string(f, 16)}:" <>
        "#{Integer.to_string(g, 16)}:#{Integer.to_string(h, 16)}"
    end
  end
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: "unknown"

  defp calculate_risk_level(score) do
    cond do
      score >= @auto_block_threshold -> :blocked
      score >= @high_risk_threshold -> :high_risk
      score >= @suspicious_threshold -> :suspicious
      true -> :normal
    end
  end

  defp clamp(value, min, max) do
    value |> max(min) |> min(max)
  end

  defp schedule_decay do
    Process.send_after(self(), :decay, @decay_interval_ms)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp decay_scores do
    :dets.foldl(fn {ip, data}, _acc ->
      # Decay toward default score
      new_score = if data.score > @default_score do
        max(data.score - @decay_amount, @default_score)
      else
        min(data.score + @decay_amount, @default_score)
      end

      if new_score != data.score do
        :dets.insert(@table, {ip, %{data | score: new_score}})
      end
    end, nil, @table)
  end

  defp cleanup_old_entries do
    cutoff = DateTime.add(DateTime.utc_now(), -@max_age_days * 24 * 60 * 60, :second)

    old = :dets.foldl(fn
      {ip, %{updated_at: updated_at, score: score}}, acc
          when is_struct(updated_at, DateTime) ->
        # Keep high-risk IPs even if old
        if DateTime.compare(updated_at, cutoff) == :lt and score < @suspicious_threshold do
          [ip | acc]
        else
          acc
        end
      {ip, %{score: score}}, acc when score < @suspicious_threshold ->
        # No timestamp, clean up if low risk
        [ip | acc]
      _, acc ->
        acc
    end, [], @table)

    Enum.each(old, &:dets.delete(@table, &1))

    if length(old) > 0 do
      :dets.sync(@table)
      Logger.info("[IpReputation] Cleaned up #{length(old)} old entries")
    end
  end
end
