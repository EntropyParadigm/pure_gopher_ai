defmodule PureGopherAi.ContentReports do
  @moduledoc """
  Content reporting system for flagging inappropriate content.

  Users can report:
  - Guestbook entries
  - Messages
  - Phlog posts/comments
  - User profiles
  - Bulletin board posts

  Reports are queued for admin review with priority scoring.
  """

  use GenServer
  require Logger

  @table :content_reports
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_reports_per_ip 10  # Per day
  @cleanup_interval_ms 24 * 60 * 60 * 1000  # Daily
  @report_ttl_days 90  # Keep resolved reports for 90 days

  # Content types
  @content_types [:guestbook, :message, :phlog, :comment, :profile, :bulletin, :poll, :paste]

  # Report reasons
  @reasons [:spam, :harassment, :illegal, :inappropriate, :copyright, :other]

  # Priority multipliers for reason severity
  @reason_priority %{
    illegal: 5,
    harassment: 4,
    copyright: 3,
    inappropriate: 2,
    spam: 1,
    other: 1
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reports content for admin review.
  """
  def report(content_type, content_id, reason, reporter_info, opts \\ [])
      when content_type in @content_types and reason in @reasons do
    GenServer.call(__MODULE__, {:report, content_type, content_id, reason, reporter_info, opts})
  end

  @doc """
  Gets pending reports for admin review.
  """
  def pending(opts \\ []) do
    GenServer.call(__MODULE__, {:pending, opts})
  end

  @doc """
  Gets a specific report.
  """
  def get(report_id) do
    GenServer.call(__MODULE__, {:get, report_id})
  end

  @doc """
  Resolves a report with an action.
  Actions: :dismissed, :warned, :removed, :banned
  """
  def resolve(report_id, action, admin_notes \\ "") do
    GenServer.call(__MODULE__, {:resolve, report_id, action, admin_notes})
  end

  @doc """
  Escalates a report priority.
  """
  def escalate(report_id) do
    GenServer.call(__MODULE__, {:escalate, report_id})
  end

  @doc """
  Gets reports for a specific content item.
  """
  def for_content(content_type, content_id) do
    GenServer.call(__MODULE__, {:for_content, content_type, content_id})
  end

  @doc """
  Gets report statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Checks if content has been reported.
  """
  def is_reported?(content_type, content_id) do
    case for_content(content_type, content_id) do
      {:ok, []} -> false
      {:ok, _reports} -> true
      _ -> false
    end
  end

  @doc """
  Returns valid content types.
  """
  def content_types, do: @content_types

  @doc """
  Returns valid report reasons.
  """
  def reasons, do: @reasons

  @doc """
  Returns a human-readable label for a reason.
  """
  def reason_label(:spam), do: "Spam"
  def reason_label(:harassment), do: "Harassment or bullying"
  def reason_label(:illegal), do: "Illegal content"
  def reason_label(:inappropriate), do: "Inappropriate content"
  def reason_label(:copyright), do: "Copyright violation"
  def reason_label(:other), do: "Other"
  def reason_label(_), do: "Unknown"

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "content_reports.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: dets_file, type: :set)

    # ETS for rate limiting
    :ets.new(:report_rate_limits, [:named_table, :public, :set])

    schedule_cleanup()

    Logger.info("[ContentReports] Started")
    {:ok, %{counter: get_counter()}}
  end

  @impl true
  def handle_call({:report, content_type, content_id, reason, reporter_info, opts}, _from, state) do
    ip = Keyword.get(reporter_info, :ip)
    username = Keyword.get(reporter_info, :username)
    ip_hash = hash_ip(ip)

    cond do
      # Rate limit check
      rate_limited?(ip_hash) ->
        {:reply, {:error, :rate_limited}, state}

      # Check for duplicate reports
      already_reported?(content_type, content_id, ip_hash) ->
        {:reply, {:error, :already_reported}, state}

      true ->
        report_id = state.counter

        report = %{
          id: report_id,
          content_type: content_type,
          content_id: content_id,
          reason: reason,
          details: Keyword.get(opts, :details, ""),
          reporter_ip_hash: ip_hash,
          reporter_username: username,
          status: :pending,
          priority: calculate_priority(reason),
          report_count: 1,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          resolved_at: nil,
          resolution: nil,
          admin_notes: nil
        }

        :dets.insert(@table, {report_id, report})
        record_rate_limit(ip_hash)

        Logger.info("[ContentReports] New report ##{report_id}: #{content_type}/#{content_id} (#{reason})")
        {:reply, {:ok, report_id}, %{state | counter: state.counter + 1}}
    end
  end

  @impl true
  def handle_call({:pending, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)

    reports = :dets.foldl(fn
      {_id, %{status: :pending} = report}, acc -> [report | acc]
      _, acc -> acc
    end, [], @table)

    # Sort by priority (descending) then by date (oldest first)
    sorted = reports
      |> Enum.sort_by(fn r -> {-r.priority, r.created_at} end)
      |> Enum.take(limit)

    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:get, report_id}, _from, state) do
    case :dets.lookup(@table, report_id) do
      [{^report_id, report}] -> {:reply, {:ok, report}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:resolve, report_id, action, admin_notes}, _from, state) do
    case :dets.lookup(@table, report_id) do
      [{^report_id, report}] ->
        updated = %{report |
          status: :resolved,
          resolution: action,
          admin_notes: admin_notes,
          resolved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :dets.insert(@table, {report_id, updated})

        Logger.info("[ContentReports] Report ##{report_id} resolved: #{action}")
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:escalate, report_id}, _from, state) do
    case :dets.lookup(@table, report_id) do
      [{^report_id, report}] ->
        updated = %{report |
          priority: report.priority + 1,
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :dets.insert(@table, {report_id, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:for_content, content_type, content_id}, _from, state) do
    reports = :dets.foldl(fn
      {_id, %{content_type: ^content_type, content_id: ^content_id} = report}, acc ->
        [report | acc]
      _, acc ->
        acc
    end, [], @table)

    {:reply, {:ok, reports}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = :dets.foldl(fn {_id, report}, acc ->
      acc
      |> Map.update(:total, 1, & &1 + 1)
      |> Map.update(report.status, 1, & &1 + 1)
      |> Map.update({:reason, report.reason}, 1, & &1 + 1)
      |> Map.update({:type, report.content_type}, 1, & &1 + 1)
    end, %{total: 0, pending: 0, resolved: 0}, @table)

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_reports()
    cleanup_rate_limits()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # Private functions

  defp hash_ip(ip) when is_tuple(ip) do
    ip_str = case ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
    end
    :crypto.hash(:sha256, ip_str) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end
  defp hash_ip(_), do: "unknown"

  defp calculate_priority(reason) do
    Map.get(@reason_priority, reason, 1)
  end

  defp rate_limited?(ip_hash) do
    today = Date.utc_today() |> Date.to_string()
    key = {ip_hash, today}

    case :ets.lookup(:report_rate_limits, key) do
      [{^key, count}] when count >= @max_reports_per_ip -> true
      _ -> false
    end
  end

  defp record_rate_limit(ip_hash) do
    today = Date.utc_today() |> Date.to_string()
    key = {ip_hash, today}

    case :ets.lookup(:report_rate_limits, key) do
      [{^key, count}] ->
        :ets.insert(:report_rate_limits, {key, count + 1})
      [] ->
        :ets.insert(:report_rate_limits, {key, 1})
    end
  end

  defp already_reported?(content_type, content_id, ip_hash) do
    :dets.foldl(fn
      {_id, %{content_type: ^content_type, content_id: ^content_id,
              reporter_ip_hash: ^ip_hash, status: :pending}}, _acc ->
        throw(:found)
      _, acc ->
        acc
    end, false, @table)
  catch
    :found -> true
  end

  defp get_counter do
    case :dets.foldl(fn {id, _}, max -> max(id, max) end, 0, @table) do
      0 -> 1
      n -> n + 1
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_old_reports do
    cutoff = DateTime.utc_now()
      |> DateTime.add(-@report_ttl_days * 24 * 60 * 60, :second)
      |> DateTime.to_iso8601()

    old = :dets.foldl(fn
      {id, %{status: :resolved, resolved_at: resolved_at}}, acc when resolved_at < cutoff ->
        [id | acc]
      _, acc ->
        acc
    end, [], @table)

    Enum.each(old, &:dets.delete(@table, &1))

    if length(old) > 0 do
      :dets.sync(@table)
      Logger.info("[ContentReports] Cleaned up #{length(old)} old reports")
    end
  end

  defp cleanup_rate_limits do
    today = Date.utc_today() |> Date.to_string()

    :ets.foldl(fn
      {{_ip, date}, _count} = entry, acc when date != today ->
        :ets.delete(:report_rate_limits, elem(entry, 0))
        acc + 1
      _, acc ->
        acc
    end, 0, :report_rate_limits)
  end
end
