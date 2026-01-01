defmodule PureGopherAi.AuditLog do
  @moduledoc """
  Audit logging for security and admin events.

  Logs events to DETS for forensic analysis and compliance.
  Events include:
  - Authentication (login, logout, failed attempts)
  - Admin actions (bans, cache clears, config changes)
  - Security events (rate limits, blocked IPs, injection attempts)
  - Content moderation (deletions, reports)

  Log retention: 30 days by default, configurable.
  """

  use GenServer
  require Logger

  @dets_file "audit_log.dets"
  @default_retention_days 30
  @cleanup_interval_ms 24 * 60 * 60 * 1000  # Daily cleanup
  @max_entries_per_query 1000

  # Event categories
  @categories [:auth, :admin, :security, :content, :system]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Logs an audit event.

  ## Parameters
  - category: :auth | :admin | :security | :content | :system
  - event: atom describing the event (e.g., :login_success, :ban_ip)
  - details: map with event-specific details
  - opts: optional metadata (ip, username, severity)

  ## Examples
      AuditLog.log(:auth, :login_success, %{username: "alice"}, ip: {127,0,0,1})
      AuditLog.log(:admin, :clear_cache, %{entries_cleared: 150}, username: "admin")
      AuditLog.log(:security, :rate_limit_exceeded, %{requests: 100}, ip: ip, severity: :warning)
  """
  def log(category, event, details \\ %{}, opts \\ [])
      when category in @categories and is_atom(event) do
    GenServer.cast(__MODULE__, {:log, category, event, details, opts})
  end

  @doc """
  Synchronous log for critical events that must be persisted.
  """
  def log_sync(category, event, details \\ %{}, opts \\ [])
      when category in @categories and is_atom(event) do
    GenServer.call(__MODULE__, {:log, category, event, details, opts})
  end

  # Convenience functions for common events

  @doc "Log successful authentication"
  def auth_success(username, opts \\ []) do
    log(:auth, :login_success, %{username: username}, opts)
  end

  @doc "Log failed authentication attempt"
  def auth_failure(username, reason, opts \\ []) do
    log(:auth, :login_failure, %{username: username, reason: reason}, Keyword.put(opts, :severity, :warning))
  end

  @doc "Log session created"
  def session_created(username, opts \\ []) do
    log(:auth, :session_created, %{username: username}, opts)
  end

  @doc "Log session invalidated (logout)"
  def session_invalidated(username, opts \\ []) do
    log(:auth, :session_invalidated, %{username: username}, opts)
  end

  @doc "Log admin action"
  def admin_action(action, details, opts \\ []) do
    log(:admin, action, details, opts)
  end

  @doc "Log IP ban"
  def ip_banned(ip, reason, opts \\ []) do
    log(:admin, :ip_banned, %{ip: format_ip(ip), reason: reason}, Keyword.put(opts, :severity, :warning))
  end

  @doc "Log IP unban"
  def ip_unbanned(ip, opts \\ []) do
    log(:admin, :ip_unbanned, %{ip: format_ip(ip)}, opts)
  end

  @doc "Log rate limit trigger"
  def rate_limited(ip, opts \\ []) do
    log(:security, :rate_limit_exceeded, %{ip: format_ip(ip)}, Keyword.put(opts, :severity, :warning))
  end

  @doc "Log blocked request (blocklist)"
  def blocked_request(ip, source, opts \\ []) do
    log(:security, :blocked_by_blocklist, %{ip: format_ip(ip), source: source}, Keyword.put(opts, :severity, :warning))
  end

  @doc "Log injection attempt detected"
  def injection_detected(type, input_preview, opts \\ []) do
    # Truncate input for safety
    preview = String.slice(to_string(input_preview), 0, 100)
    log(:security, :injection_attempt, %{type: type, input_preview: preview}, Keyword.put(opts, :severity, :error))
  end

  @doc "Log content deleted"
  def content_deleted(content_type, content_id, reason, opts \\ []) do
    log(:content, :content_deleted, %{type: content_type, id: content_id, reason: reason}, opts)
  end

  @doc "Log content reported"
  def content_reported(content_type, content_id, opts \\ []) do
    log(:content, :content_reported, %{type: content_type, id: content_id}, opts)
  end

  @doc "Log content moderation block"
  def content_blocked(content_type, reason, opts \\ []) do
    log(:content, :content_blocked, %{type: content_type, reason: reason}, Keyword.put(opts, :severity, :warning))
  end

  @doc """
  Query audit logs with filters.

  ## Options
  - category: filter by category
  - event: filter by specific event
  - username: filter by username
  - ip: filter by IP address
  - severity: filter by severity
  - since: DateTime, only events after this time
  - until: DateTime, only events before this time
  - limit: max results (default 100)
  """
  def query(opts \\ []) do
    GenServer.call(__MODULE__, {:query, opts})
  end

  @doc "Get recent events (last N entries)"
  def recent(limit \\ 50) do
    query(limit: limit)
  end

  @doc "Get events for a specific IP"
  def by_ip(ip, opts \\ []) do
    query(Keyword.put(opts, :ip, format_ip(ip)))
  end

  @doc "Get events for a specific user"
  def by_user(username, opts \\ []) do
    query(Keyword.put(opts, :username, username))
  end

  @doc "Get security events"
  def security_events(opts \\ []) do
    query(Keyword.put(opts, :category, :security))
  end

  @doc "Get auth events"
  def auth_events(opts \\ []) do
    query(Keyword.put(opts, :category, :auth))
  end

  @doc "Get statistics"
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Export logs to text format"
  def export(opts \\ []) do
    GenServer.call(__MODULE__, {:export, opts})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Application.get_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
    dets_path = Path.join([Path.expand(data_dir), @dets_file]) |> String.to_charlist()

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(to_string(dets_path)))

    {:ok, dets} = :dets.open_file(:audit_log, [
      file: dets_path,
      type: :set,
      auto_save: 60_000
    ])

    # Schedule daily cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)

    Logger.info("[AuditLog] Started, retention: #{@default_retention_days} days")
    {:ok, %{dets: dets, counter: get_counter(dets)}}
  end

  @impl true
  def handle_cast({:log, category, event, details, opts}, state) do
    entry = build_entry(category, event, details, opts, state.counter)
    :dets.insert(state.dets, {state.counter, entry})
    {:noreply, %{state | counter: state.counter + 1}}
  end

  @impl true
  def handle_call({:log, category, event, details, opts}, _from, state) do
    entry = build_entry(category, event, details, opts, state.counter)
    :dets.insert(state.dets, {state.counter, entry})
    :dets.sync(state.dets)
    {:reply, :ok, %{state | counter: state.counter + 1}}
  end

  @impl true
  def handle_call({:query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100) |> min(@max_entries_per_query)

    entries = :dets.foldl(fn {_id, entry}, acc ->
      if matches_filters?(entry, opts) do
        [entry | acc]
      else
        acc
      end
    end, [], state.dets)

    # Sort by timestamp descending and limit
    result = entries
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = :dets.foldl(fn {_id, entry}, acc ->
      acc
      |> Map.update(:total, 1, & &1 + 1)
      |> Map.update(entry.category, 1, & &1 + 1)
      |> Map.update(entry.severity, 1, & &1 + 1)
    end, %{total: 0}, state.dets)

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_call({:export, opts}, _from, state) do
    {:ok, entries} = handle_call({:query, opts}, nil, state)
    {:reply, entries, format_export(entries)}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleaned = cleanup_old_entries(state.dets)
    if cleaned > 0 do
      Logger.info("[AuditLog] Cleaned #{cleaned} old entries")
    end
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.dets)
    :ok
  end

  # Private functions

  defp build_entry(category, event, details, opts, id) do
    %{
      id: id,
      timestamp: DateTime.utc_now(),
      category: category,
      event: event,
      severity: Keyword.get(opts, :severity, :info),
      username: Keyword.get(opts, :username),
      ip: case Keyword.get(opts, :ip) do
        nil -> nil
        ip when is_tuple(ip) -> format_ip(ip)
        ip -> ip
      end,
      details: details
    }
  end

  defp matches_filters?(entry, opts) do
    Enum.all?(opts, fn
      {:category, cat} -> entry.category == cat
      {:event, evt} -> entry.event == evt
      {:username, user} -> entry.username == user
      {:ip, ip} -> entry.ip == ip
      {:severity, sev} -> entry.severity == sev
      {:since, dt} -> DateTime.compare(entry.timestamp, dt) in [:gt, :eq]
      {:until, dt} -> DateTime.compare(entry.timestamp, dt) in [:lt, :eq]
      {:limit, _} -> true
      _ -> true
    end)
  end

  defp cleanup_old_entries(dets) do
    retention_days = Application.get_env(:pure_gopher_ai, :audit_retention_days, @default_retention_days)
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 24 * 60 * 60, :second)

    old_ids = :dets.foldl(fn {id, entry}, acc ->
      if DateTime.compare(entry.timestamp, cutoff) == :lt do
        [id | acc]
      else
        acc
      end
    end, [], dets)

    Enum.each(old_ids, &:dets.delete(dets, &1))
    length(old_ids)
  end

  defp get_counter(dets) do
    case :dets.foldl(fn {id, _}, max -> max(id, max) end, 0, dets) do
      0 -> 1
      n -> n + 1
    end
  end

  defp format_ip(ip) when is_tuple(ip) do
    ip |> Tuple.to_list() |> Enum.join(".")
  end
  defp format_ip(ip), do: to_string(ip)

  defp format_export(entries) do
    entries
    |> Enum.map(fn e ->
      "[#{e.timestamp}] [#{e.severity}] [#{e.category}] #{e.event}" <>
      if(e.username, do: " user=#{e.username}", else: "") <>
      if(e.ip, do: " ip=#{e.ip}", else: "") <>
      " #{inspect(e.details)}"
    end)
    |> Enum.join("\n")
  end
end
