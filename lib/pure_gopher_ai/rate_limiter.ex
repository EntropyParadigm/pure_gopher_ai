defmodule PureGopherAi.RateLimiter do
  @moduledoc """
  Rate limiter using ETS for tracking requests per IP.
  Uses a sliding window algorithm for accurate rate limiting.

  ## Features
  - Sliding window rate limiting
  - IP banning (manual and automatic)
  - Abuse pattern detection
  - Automatic ban on repeated violations

  ## Configuration
  - `:rate_limit_requests` - max requests per window (default: 60)
  - `:rate_limit_window_ms` - window size in milliseconds (default: 60000 = 1 minute)
  - `:rate_limit_enabled` - enable/disable (default: true)
  - `:rate_limit_auto_ban` - auto-ban after repeated violations (default: true)
  - `:rate_limit_ban_threshold` - violations before auto-ban (default: 5)
  """

  use GenServer
  require Logger

  @table_name :rate_limiter
  @bans_table :rate_limiter_bans
  @abuse_table :rate_limiter_abuse
  @cleanup_interval 60_000  # Clean up old entries every minute
  @burst_window_ms 5_000     # 5 second window for burst detection
  @burst_threshold 20        # More than 20 requests in 5 seconds = burst

  # Client API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request from the given IP is allowed.
  Returns {:ok, remaining} if allowed, {:error, :rate_limited, retry_after_ms} if not.
  """
  def check(ip) when is_tuple(ip) do
    check(format_ip(ip))
  end

  def check(ip) when is_binary(ip) do
    cond do
      banned?(ip) ->
        {:error, :banned}

      PureGopherAi.Blocklist.blocked?(ip) ->
        {:error, :blocklisted}

      enabled?() ->
        GenServer.call(__MODULE__, {:check, ip})

      true ->
        {:ok, :unlimited}
    end
  end

  @doc """
  Returns the current request count for an IP.
  """
  def get_count(ip) when is_tuple(ip) do
    get_count(format_ip(ip))
  end

  def get_count(ip) when is_binary(ip) do
    case :ets.lookup(@table_name, ip) do
      [{^ip, timestamps}] -> length(timestamps)
      [] -> 0
    end
  end

  @doc """
  Resets the rate limit for an IP.
  """
  def reset(ip) when is_tuple(ip) do
    reset(format_ip(ip))
  end

  def reset(ip) when is_binary(ip) do
    :ets.delete(@table_name, ip)
    :ok
  end

  @doc """
  Checks if rate limiting is enabled.
  """
  def enabled? do
    Application.get_env(:pure_gopher_ai, :rate_limit_enabled, true)
  end

  @doc """
  Gets the configured rate limit.
  """
  def limit do
    Application.get_env(:pure_gopher_ai, :rate_limit_requests, 60)
  end

  @doc """
  Gets the configured window size in milliseconds.
  """
  def window_ms do
    Application.get_env(:pure_gopher_ai, :rate_limit_window_ms, 60_000)
  end

  @doc """
  Gets rate limiter statistics.
  """
  def stats do
    tracked_ips = :ets.info(@table_name, :size) || 0
    banned_ips = :ets.info(@bans_table, :size) || 0

    %{
      enabled: enabled?(),
      limit: limit(),
      window_ms: window_ms(),
      tracked_ips: tracked_ips,
      banned_ips: banned_ips
    }
  end

  @doc """
  Bans an IP address.
  """
  def ban(ip) when is_tuple(ip) do
    ban(format_ip(ip))
  end

  def ban(ip) when is_binary(ip) do
    :ets.insert(@bans_table, {ip, System.monotonic_time(:second)})
    Logger.warning("Banned IP: #{hash_ip_for_log(ip)}")
    :ok
  end

  @doc """
  Unbans an IP address.
  """
  def unban(ip) when is_tuple(ip) do
    unban(format_ip(ip))
  end

  def unban(ip) when is_binary(ip) do
    :ets.delete(@bans_table, ip)
    Logger.info("Unbanned IP: #{hash_ip_for_log(ip)}")
    :ok
  end

  @doc """
  Checks if an IP is banned.
  """
  def banned?(ip) when is_tuple(ip) do
    banned?(format_ip(ip))
  end

  def banned?(ip) when is_binary(ip) do
    case :ets.lookup(@bans_table, ip) do
      [{^ip, _}] -> true
      [] -> false
    end
  end

  @doc """
  Lists all banned IPs.
  """
  def list_bans do
    :ets.tab2list(@bans_table)
    |> Enum.map(fn {ip, timestamp} -> {ip, timestamp} end)
  end

  @doc """
  Records a rate limit violation for abuse detection.
  May trigger auto-ban if threshold is exceeded.
  """
  def record_violation(ip) when is_tuple(ip), do: record_violation(format_ip(ip))

  def record_violation(ip) when is_binary(ip) do
    GenServer.cast(__MODULE__, {:record_violation, ip})
  end

  @doc """
  Checks for abuse patterns in recent requests.

  Returns:
  - `:ok` if no abuse detected
  - `{:burst, count}` if burst detected
  - `{:repeated_violations, count}` if repeated rate limit violations
  """
  def check_abuse(ip) when is_tuple(ip), do: check_abuse(format_ip(ip))

  def check_abuse(ip) when is_binary(ip) do
    now = System.monotonic_time(:millisecond)
    burst_cutoff = now - @burst_window_ms

    # Check for burst pattern
    case :ets.lookup(@table_name, ip) do
      [{^ip, timestamps}] ->
        recent = Enum.filter(timestamps, &(&1 > burst_cutoff))
        burst_count = length(recent)

        if burst_count > @burst_threshold do
          {:burst, burst_count}
        else
          check_violations(ip)
        end

      [] ->
        check_violations(ip)
    end
  end

  defp check_violations(ip) do
    threshold = ban_threshold()

    case :ets.lookup(@abuse_table, ip) do
      [{^ip, violations, _last_violation}] ->
        if violations >= threshold do
          {:repeated_violations, violations}
        else
          {:warning, violations}
        end

      [] ->
        :ok
    end
  end

  @doc """
  Gets abuse statistics for an IP.
  """
  def get_abuse_stats(ip) when is_tuple(ip), do: get_abuse_stats(format_ip(ip))

  def get_abuse_stats(ip) when is_binary(ip) do
    violations =
      case :ets.lookup(@abuse_table, ip) do
        [{^ip, count, last}] -> %{count: count, last_violation: last}
        [] -> %{count: 0, last_violation: nil}
      end

    request_count = get_count(ip)
    is_banned = banned?(ip)

    %{
      ip: ip,
      violations: violations,
      request_count: request_count,
      banned: is_banned,
      abuse_status: check_abuse(ip)
    }
  end

  @doc """
  Returns the auto-ban setting.
  """
  def auto_ban_enabled? do
    Application.get_env(:pure_gopher_ai, :rate_limit_auto_ban, true)
  end

  @doc """
  Returns the violation threshold for auto-ban.
  """
  def ban_threshold do
    Application.get_env(:pure_gopher_ai, :rate_limit_ban_threshold, 5)
  end

  @doc """
  Clears abuse records for an IP.
  """
  def clear_abuse(ip) when is_tuple(ip), do: clear_abuse(format_ip(ip))

  def clear_abuse(ip) when is_binary(ip) do
    :ets.delete(@abuse_table, ip)
    :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables with read_concurrency for per-request checks
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ets.new(@bans_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@abuse_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("RateLimiter started: #{limit()} requests per #{div(window_ms(), 1000)}s")
    Logger.info("Auto-ban: #{auto_ban_enabled?()}, threshold: #{ban_threshold()} violations")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check, ip}, _from, state) do
    now = System.monotonic_time(:millisecond)
    window = window_ms()
    max_requests = limit()
    cutoff = now - window

    # Get existing timestamps, filter out old ones
    timestamps =
      case :ets.lookup(@table_name, ip) do
        [{^ip, ts}] -> Enum.filter(ts, &(&1 > cutoff))
        [] -> []
      end

    current_count = length(timestamps)

    if current_count < max_requests do
      # Allow request, add timestamp
      new_timestamps = [now | timestamps]
      :ets.insert(@table_name, {ip, new_timestamps})
      remaining = max_requests - current_count - 1
      {:reply, {:ok, remaining}, state}
    else
      # Rate limited - calculate retry after
      oldest = Enum.min(timestamps)
      retry_after = oldest + window - now
      {:reply, {:error, :rate_limited, retry_after}, state}
    end
  end

  @impl true
  def handle_cast({:record_violation, ip}, state) do
    now = System.monotonic_time(:second)

    # Update violation count
    {new_count, _} =
      case :ets.lookup(@abuse_table, ip) do
        [{^ip, count, _last}] ->
          new_count = count + 1
          :ets.insert(@abuse_table, {ip, new_count, now})
          {new_count, now}

        [] ->
          :ets.insert(@abuse_table, {ip, 1, now})
          {1, now}
      end

    # Check for auto-ban
    if auto_ban_enabled?() and new_count >= ban_threshold() do
      Logger.warning("Auto-banning IP #{hash_ip_for_log(ip)} after #{new_count} violations")
      ban(ip)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_entries()
    cleanup_old_abuse_records()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_old_entries do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms()

    # Iterate through all entries and clean up old timestamps
    :ets.foldl(
      fn {ip, timestamps}, acc ->
        filtered = Enum.filter(timestamps, &(&1 > cutoff))

        if filtered == [] do
          :ets.delete(@table_name, ip)
        else
          :ets.insert(@table_name, {ip, filtered})
        end

        acc
      end,
      :ok,
      @table_name
    )
  end

  defp cleanup_old_abuse_records do
    # Clear abuse records older than 1 hour
    now = System.monotonic_time(:second)
    cutoff = now - 3600

    :ets.foldl(
      fn {ip, _count, last_violation}, acc ->
        if last_violation < cutoff do
          :ets.delete(@abuse_table, ip)
        end
        acc
      end,
      :ok,
      @abuse_table
    )
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip) when is_binary(ip), do: ip

  # Hash IP for privacy-friendly logging (first 8 chars of SHA256)
  defp hash_ip_for_log(ip) do
    ip_str = format_ip(ip)
    :crypto.hash(:sha256, ip_str)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end
end
