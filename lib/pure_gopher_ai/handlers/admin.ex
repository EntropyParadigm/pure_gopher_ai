defmodule PureGopherAi.Handlers.Admin do
  @moduledoc """
  Admin interface handlers for Gopher protocol.

  Token-protected administrative functions for:
  - Cache management
  - Session management
  - Rate limiter/ban management
  - RAG document management
  - Metrics reset
  """

  require Logger

  alias PureGopherAi.Handlers.Shared
  alias PureGopherAi.Admin
  alias PureGopherAi.Telemetry
  alias PureGopherAi.Rag

  @doc """
  Handle admin route - entry point for all admin operations.
  """
  def handle_admin(path, host, port) do
    if not Admin.enabled?() do
      Shared.error_response("Admin interface not configured")
    else
      case String.split(path, "/", parts: 2) do
        [token] ->
          if Admin.valid_token?(token) do
            admin_menu(token, host, port)
          else
            Shared.error_response("Invalid admin token")
          end

        [token, command] ->
          if Admin.valid_token?(token) do
            handle_admin_command(token, command, host, port)
          else
            Shared.error_response("Invalid admin token")
          end

        _ ->
          Shared.error_response("Invalid admin path")
      end
    end
  end

  @doc """
  Admin dashboard menu.
  """
  def admin_menu(token, host, port) do
    system_stats = Admin.system_stats()
    cache_stats = Admin.cache_stats()
    rate_stats = Admin.rate_limiter_stats()
    telemetry = Telemetry.format_stats()

    [
      Shared.info_line("=== Admin Panel ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- System Status ---", host, port),
      Shared.info_line("Uptime: #{system_stats.uptime_hours} hours", host, port),
      Shared.info_line("Processes: #{system_stats.processes}", host, port),
      Shared.info_line("Memory: #{system_stats.memory.total_mb} MB total", host, port),
      Shared.info_line("  Processes: #{system_stats.memory.processes_mb} MB", host, port),
      Shared.info_line("  ETS: #{system_stats.memory.ets_mb} MB", host, port),
      Shared.info_line("  Binary: #{system_stats.memory.binary_mb} MB", host, port),
      Shared.info_line("Schedulers: #{system_stats.schedulers}", host, port),
      Shared.info_line("OTP: #{system_stats.otp_version} | Elixir: #{system_stats.elixir_version}", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- Request Stats ---", host, port),
      Shared.info_line("Total Requests: #{telemetry.total_requests}", host, port),
      Shared.info_line("Requests/Hour: #{telemetry.requests_per_hour}", host, port),
      Shared.info_line("Errors: #{telemetry.total_errors} (#{telemetry.error_rate}%)", host, port),
      Shared.info_line("Avg Latency: #{telemetry.avg_latency_ms}ms", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- Cache ---", host, port),
      Shared.info_line("Size: #{cache_stats.size}/#{cache_stats.max_size}", host, port),
      Shared.info_line("Hit Rate: #{cache_stats.hit_rate}%", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- Rate Limiter ---", host, port),
      Shared.info_line("Tracked IPs: #{rate_stats.tracked_ips}", host, port),
      Shared.info_line("Banned IPs: #{rate_stats.banned_ips}", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- Actions ---", host, port),
      Shared.text_link("Clear Cache", "/admin/#{token}/clear-cache", host, port),
      Shared.text_link("Clear Sessions", "/admin/#{token}/clear-sessions", host, port),
      Shared.text_link("Reset Metrics", "/admin/#{token}/reset-metrics", host, port),
      Shared.link_line("View Bans", "/admin/#{token}/bans", host, port),
      Shared.link_line("Manage Documents (RAG)", "/admin/#{token}/docs", host, port),
      Shared.link_line("Audit Log", "/admin/#{token}/audit", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Main Menu", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  # === Admin Commands ===

  def handle_admin_command(token, "clear-cache", host, port) do
    Admin.clear_cache()
    admin_action_result(token, "Cache cleared successfully", host, port)
  end

  def handle_admin_command(token, "clear-sessions", host, port) do
    Admin.clear_sessions()
    admin_action_result(token, "All sessions cleared", host, port)
  end

  def handle_admin_command(token, "reset-metrics", host, port) do
    Admin.reset_metrics()
    admin_action_result(token, "Metrics reset", host, port)
  end

  def handle_admin_command(token, "bans", host, port) do
    bans = Admin.list_bans()

    ban_lines = if Enum.empty?(bans) do
      [Shared.info_line("No banned IPs", host, port)]
    else
      bans
      |> Enum.map(fn {ip, _timestamp} ->
        [
          Shared.info_line("  #{ip}", host, port),
          Shared.text_link("Unban #{ip}", "/admin/#{token}/unban/#{ip}", host, port)
        ]
      end)
    end

    [
      Shared.info_line("=== Banned IPs ===", host, port),
      Shared.info_line("", host, port),
      ban_lines,
      Shared.info_line("", host, port),
      Shared.search_line("Ban IP", "/admin/#{token}/ban", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Admin", "/admin/#{token}", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  def handle_admin_command(token, "ban\t" <> ip, host, port) do
    handle_ban(token, ip, host, port)
  end

  def handle_admin_command(token, "ban " <> ip, host, port) do
    handle_ban(token, ip, host, port)
  end

  def handle_admin_command(token, "unban/" <> ip, host, port) do
    case Admin.unban_ip(ip) do
      :ok ->
        admin_action_result(token, "Unbanned IP: #{ip}", host, port)
      {:error, :invalid_ip} ->
        admin_action_result(token, "Invalid IP address: #{ip}", host, port)
    end
  end

  # RAG admin commands
  def handle_admin_command(token, "docs", host, port) do
    stats = Rag.stats()

    doc_lines = case Rag.list_documents() do
      {:ok, []} ->
        [Shared.info_line("No documents ingested", host, port)]

      {:ok, docs} ->
        docs
        |> Enum.map(fn doc ->
          [
            Shared.info_line("  - #{doc.name} (#{doc.chunks} chunks)", host, port),
            Shared.text_link("    Remove", "/admin/#{token}/remove-doc/#{doc.id}", host, port)
          ]
        end)

      {:error, _} ->
        [Shared.info_line("Error loading documents", host, port)]
    end

    [
      Shared.info_line("=== RAG Document Status ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Documents: #{stats.document_count}", host, port),
      Shared.info_line("Chunks: #{stats.chunk_count}", host, port),
      Shared.info_line("Embeddings: #{if stats.embeddings_enabled, do: "Enabled", else: "Disabled"}", host, port),
      Shared.info_line("Docs Directory: #{Rag.docs_dir()}", host, port),
      Shared.info_line("", host, port),
      doc_lines,
      Shared.info_line("", host, port),
      Shared.search_line("Ingest file path", "/admin/#{token}/ingest", host, port),
      Shared.search_line("Ingest URL", "/admin/#{token}/ingest-url", host, port),
      Shared.text_link("Clear all documents", "/admin/#{token}/clear-docs", host, port),
      Shared.text_link("Re-embed all chunks", "/admin/#{token}/reembed", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Admin Menu", "/admin/#{token}", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  def handle_admin_command(token, "ingest\t" <> path, host, port) do
    handle_admin_ingest(token, path, host, port)
  end

  def handle_admin_command(token, "ingest " <> path, host, port) do
    handle_admin_ingest(token, path, host, port)
  end

  def handle_admin_command(token, "ingest-url\t" <> url, host, port) do
    handle_admin_ingest_url(token, url, host, port)
  end

  def handle_admin_command(token, "ingest-url " <> url, host, port) do
    handle_admin_ingest_url(token, url, host, port)
  end

  def handle_admin_command(token, "clear-docs", host, port) do
    PureGopherAi.Rag.DocumentStore.clear_all()
    admin_action_result(token, "Cleared all documents and chunks", host, port)
  end

  def handle_admin_command(token, "reembed", host, port) do
    PureGopherAi.Rag.Embeddings.embed_all_chunks()
    admin_action_result(token, "Re-embedding all chunks (running in background)", host, port)
  end

  def handle_admin_command(token, "remove-doc/" <> doc_id, host, port) do
    case Rag.remove(doc_id) do
      :ok ->
        admin_action_result(token, "Removed document: #{doc_id}", host, port)
      {:error, reason} ->
        admin_action_result(token, "Failed to remove: #{Shared.sanitize_error(reason)}", host, port)
    end
  end

  # Audit Log routes (delegate to SecurityHandler)
  def handle_admin_command(token, "audit", host, port) do
    PureGopherAi.Handlers.Security.audit_menu(token, host, port)
  end

  def handle_admin_command(token, "audit/recent", host, port) do
    PureGopherAi.Handlers.Security.audit_recent(token, host, port)
  end

  def handle_admin_command(token, "audit/security", host, port) do
    PureGopherAi.Handlers.Security.audit_security(token, host, port)
  end

  def handle_admin_command(token, "audit/auth", host, port) do
    PureGopherAi.Handlers.Security.audit_auth(token, host, port)
  end

  def handle_admin_command(token, "audit/ip\t" <> ip, host, port) do
    PureGopherAi.Handlers.Security.audit_by_ip(token, String.trim(ip), host, port)
  end

  def handle_admin_command(token, "audit/ip " <> ip, host, port) do
    PureGopherAi.Handlers.Security.audit_by_ip(token, String.trim(ip), host, port)
  end

  def handle_admin_command(token, "audit/user\t" <> username, host, port) do
    PureGopherAi.Handlers.Security.audit_by_user(token, String.trim(username), host, port)
  end

  def handle_admin_command(token, "audit/user " <> username, host, port) do
    PureGopherAi.Handlers.Security.audit_by_user(token, String.trim(username), host, port)
  end

  def handle_admin_command(_token, command, _host, _port) do
    Shared.error_response("Unknown admin command: #{command}")
  end

  # === Helper Functions ===

  defp handle_admin_ingest(token, path, host, port) do
    path = String.trim(path)
    case Rag.ingest(path) do
      {:ok, doc} ->
        admin_action_result(token, "Ingested: #{doc.name} (#{doc.chunks} chunks)", host, port)
      {:error, :file_not_found} ->
        admin_action_result(token, "File not found: #{path}", host, port)
      {:error, :already_ingested} ->
        admin_action_result(token, "Already ingested: #{path}", host, port)
      {:error, reason} ->
        admin_action_result(token, "Ingest failed: #{Shared.sanitize_error(reason)}", host, port)
    end
  end

  defp handle_admin_ingest_url(token, url, host, port) do
    url = String.trim(url)
    case Rag.ingest_url(url) do
      {:ok, doc} ->
        admin_action_result(token, "Ingested from URL: #{doc.name} (#{doc.chunks} chunks)", host, port)
      {:error, {:http_error, status}} ->
        admin_action_result(token, "HTTP error: #{status}", host, port)
      {:error, reason} ->
        admin_action_result(token, "Ingest failed: #{Shared.sanitize_error(reason)}", host, port)
    end
  end

  defp handle_ban(token, ip, host, port) do
    ip = String.trim(ip)
    case Admin.ban_ip(ip) do
      :ok ->
        admin_action_result(token, "Banned IP: #{ip}", host, port)
      {:error, :invalid_ip} ->
        admin_action_result(token, "Invalid IP address: #{ip}", host, port)
    end
  end

  defp admin_action_result(token, message, host, port) do
    [
      Shared.info_line("=== Admin Action ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line(message, host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Admin", "/admin/#{token}", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end
end
