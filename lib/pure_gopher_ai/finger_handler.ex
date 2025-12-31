defmodule PureGopherAi.FingerHandler do
  @moduledoc """
  Finger protocol handler (RFC 1288).

  The Finger protocol is a simple user information lookup protocol.
  - Default port: 79
  - Request: <username>\r\n or just \r\n for server info
  - Response: User info text, then close connection

  Supports:
  - User .plan file serving
  - Server info display
  - AI-enhanced user profiles
  """

  use ThousandIsland.Handler
  require Logger

  alias PureGopherAi.RateLimiter

  @plan_dir Application.compile_env(:pure_gopher_ai, :finger_plan_dir, "~/.gopher/finger")
  @max_username_length 64

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    client_ip =
      case ThousandIsland.Socket.peername(socket) do
        {:ok, {ip, _port}} -> ip
        _ -> {0, 0, 0, 0}
      end

    {:continue, %{client_ip: client_ip}}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    client_ip = Map.get(state, :client_ip, {0, 0, 0, 0})

    case RateLimiter.check(client_ip) do
      {:ok, _remaining} ->
        request = String.trim(data)
        Logger.info("[Finger] Request: '#{request}' from #{format_ip(client_ip)}")

        response = handle_finger_request(request)
        ThousandIsland.Socket.send(socket, response)

      {:error, :rate_limited, _retry_after} ->
        Logger.warning("[Finger] Rate limited: #{format_ip(client_ip)}")
        ThousandIsland.Socket.send(socket, "Rate limited. Please try again later.\r\n")

      {:error, :banned} ->
        Logger.warning("[Finger] Banned IP: #{format_ip(client_ip)}")
        ThousandIsland.Socket.send(socket, "Access denied.\r\n")

      {:error, :blocklisted} ->
        Logger.warning("[Finger] Blocklisted IP: #{format_ip(client_ip)}")
        ThousandIsland.Socket.send(socket, "Access denied.\r\n")
    end

    {:close, state}
  end

  # Handle finger requests
  defp handle_finger_request(""), do: server_info()
  defp handle_finger_request("/W"), do: server_info()  # Whois-style verbose
  defp handle_finger_request("/W " <> username), do: user_info(username, verbose: true)

  defp handle_finger_request(request) do
    # Parse: [/W] username[@host]
    {verbose, query} = if String.starts_with?(request, "/W ") do
      {true, String.replace_prefix(request, "/W ", "")}
    else
      {false, request}
    end

    # Handle remote queries (username@host) - we don't forward, just show local
    username = case String.split(query, "@", parts: 2) do
      [user, _host] -> user
      [user] -> user
    end

    username = String.trim(username)

    if valid_username?(username) do
      user_info(username, verbose: verbose)
    else
      "Invalid username.\r\n"
    end
  end

  # Server info when no username specified
  defp server_info do
    uptime = System.system_time(:second) - Application.get_env(:pure_gopher_ai, :start_time, System.system_time(:second))
    days = div(uptime, 86400)
    hours = div(rem(uptime, 86400), 3600)
    minutes = div(rem(uptime, 3600), 60)

    users = list_users()
    user_list = if length(users) > 0 do
      users
      |> Enum.take(20)
      |> Enum.map(fn user -> "  #{user}" end)
      |> Enum.join("\n")
    else
      "  (no users configured)"
    end

    """
    ╔══════════════════════════════════════════════════════════════════╗
    ║                      PureGopherAI Finger Server                  ║
    ╚══════════════════════════════════════════════════════════════════╝

    Welcome to the PureGopherAI finger service!

    This server provides:
    • AI-powered Gopher/Gemini services
    • User .plan file hosting
    • Community features (guestbook, bulletin board)

    Server Stats:
      Uptime: #{days} days, #{hours} hours, #{minutes} minutes
      Elixir: #{System.version()}
      OTP: #{:erlang.system_info(:otp_release)}

    Known Users:
    #{user_list}

    To finger a specific user, try: finger username@#{get_hostname()}

    Also available:
    • Gopher: gopher://#{get_hostname()}/
    • Gemini: gemini://#{get_hostname()}/

    Happy fingering!
    """
  end

  # User info
  defp user_info(username, opts) do
    verbose = Keyword.get(opts, :verbose, false)
    plan_dir = Path.expand(@plan_dir)
    plan_file = Path.join(plan_dir, "#{username}.plan")

    cond do
      not File.exists?(plan_dir) ->
        "User '#{username}' not found.\r\n"

      File.exists?(plan_file) ->
        plan_content = File.read!(plan_file)
        format_user_plan(username, plan_content, verbose)

      true ->
        "User '#{username}' has no .plan file.\r\n"
    end
  end

  defp format_user_plan(username, plan_content, verbose) do
    header = """
    ┌──────────────────────────────────────────────────────────────────┐
    │ User: #{String.pad_trailing(username, 57)} │
    └──────────────────────────────────────────────────────────────────┘

    """

    plan_section = """
    Plan:
    ────────────────────────────────────────────────────────────────────
    #{plan_content}
    ────────────────────────────────────────────────────────────────────
    """

    extra = if verbose do
      """

      Additional Info:
      • Finger service: PureGopherAI
      • Protocol: RFC 1288
      • Query time: #{DateTime.utc_now() |> DateTime.to_string()}
      """
    else
      ""
    end

    header <> plan_section <> extra
  end

  # List available users (those with .plan files)
  defp list_users do
    plan_dir = Path.expand(@plan_dir)

    if File.exists?(plan_dir) do
      plan_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".plan"))
      |> Enum.map(&String.replace_suffix(&1, ".plan", ""))
      |> Enum.sort()
    else
      []
    end
  end

  defp valid_username?(username) do
    byte_size(username) > 0 and
    byte_size(username) <= @max_username_length and
    String.match?(username, ~r/^[a-zA-Z0-9_-]+$/) and
    not String.contains?(username, "..")
  end

  defp get_hostname do
    Application.get_env(:pure_gopher_ai, :hostname, "localhost")
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip), do: inspect(ip)
end
