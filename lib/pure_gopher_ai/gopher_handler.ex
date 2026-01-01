defmodule PureGopherAi.GopherHandler do
  @moduledoc """
  Gopher protocol handler implementing RFC 1436.
  Uses ThousandIsland for TCP connection handling.
  Supports both clearnet and Tor hidden service connections.
  Serves static content via gophermap.
  Implements rate limiting per IP.
  """

  use ThousandIsland.Handler
  require Logger

  alias PureGopherAi.Gophermap
  alias PureGopherAi.RateLimiter
  alias PureGopherAi.Telemetry
  alias PureGopherAi.Phlog
  alias PureGopherAi.Adventure
  alias PureGopherAi.FeedAggregator
  alias PureGopherAi.Weather
  alias PureGopherAi.Fortune
  alias PureGopherAi.LinkDirectory
  alias PureGopherAi.BulletinBoard
  alias PureGopherAi.HealthCheck
  alias PureGopherAi.InputSanitizer
  alias PureGopherAi.PhlogComments
  alias PureGopherAi.UserProfiles
  alias PureGopherAi.Calendar
  alias PureGopherAi.UrlShortener
  alias PureGopherAi.Utilities
  alias PureGopherAi.Sitemap
  alias PureGopherAi.Mailbox
  alias PureGopherAi.Trivia
  alias PureGopherAi.Bookmarks
  alias PureGopherAi.UnitConverter
  alias PureGopherAi.Calculator
  alias PureGopherAi.Games
  alias PureGopherAi.UserPhlog
  alias PureGopherAi.ServerDirectory
  alias PureGopherAi.CrawlerHints
  alias PureGopherAi.Caps
  alias PureGopherAi.PhlogFormatter
  alias PureGopherAi.PhlogArt
  alias PureGopherAi.AnsiArt
  alias PureGopherAi.Slides
  alias PureGopherAi.SlideRenderer
  alias PureGopherAi.WritingAssistant
  alias PureGopherAi.SemanticSearch
  alias PureGopherAi.CreativeStudio

  # Handler modules (extracted for modularity)
  alias PureGopherAi.Handlers.Ai, as: AiHandler
  alias PureGopherAi.Handlers.Community, as: CommunityHandler
  alias PureGopherAi.Handlers.Tools, as: ToolsHandler
  alias PureGopherAi.Handlers.Admin, as: AdminHandler
  alias PureGopherAi.Handlers.Shared, as: SharedHandler
  alias PureGopherAi.Handlers.Security, as: SecurityHandler

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    # Extract network type and client IP
    network = Keyword.get(state, :network, :clearnet)

    client_ip =
      case ThousandIsland.Socket.peername(socket) do
        {:ok, {ip, _port}} -> ip
        _ -> {0, 0, 0, 0}
      end

    {:continue, %{network: network, client_ip: client_ip}}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    network = Map.get(state, :network, :clearnet)
    client_ip = Map.get(state, :client_ip, {0, 0, 0, 0})
    {host, port} = get_host_port(network)

    # Check rate limit
    case RateLimiter.check(client_ip) do
      {:ok, _remaining} ->
        # Gopher selectors are CRLF terminated
        selector =
          data
          |> String.trim()
          |> String.trim_trailing("\r\n")

        network_label = if network == :tor, do: "[Tor]", else: "[Clearnet]"
        Logger.info("#{network_label} Gopher request: #{inspect(selector)} from #{hash_ip_for_log(client_ip)}")

        # Record telemetry
        Telemetry.record_request(selector, network: network)

        # Route selector - pass socket for streaming support
        case route_selector(selector, host, port, network, client_ip, socket) do
          :streamed ->
            # Response already sent via streaming
            :ok

          response when is_binary(response) ->
            ThousandIsland.Socket.send(socket, response)
        end

      {:error, :rate_limited, retry_after} ->
        Logger.warning("Rate limited: #{hash_ip_for_log(client_ip)}, retry after #{retry_after}ms")
        # Record violation for abuse detection (may trigger auto-ban)
        RateLimiter.record_violation(client_ip)
        response = SharedHandler.rate_limit_response(retry_after)
        ThousandIsland.Socket.send(socket, response)

      {:error, :banned} ->
        Logger.warning("Banned IP attempted access: #{hash_ip_for_log(client_ip)}")
        response = SharedHandler.banned_response()
        ThousandIsland.Socket.send(socket, response)

      {:error, :blocklisted} ->
        Logger.warning("Blocklisted IP attempted access: #{hash_ip_for_log(client_ip)}")
        response = SharedHandler.blocklisted_response()
        ThousandIsland.Socket.send(socket, response)
    end

    {:close, state}
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip), do: inspect(ip)

  # Hash IP for privacy-friendly logging (first 8 chars of SHA256)
  defp hash_ip_for_log(ip) do
    ip_str = format_ip(ip)
    :crypto.hash(:sha256, ip_str)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> default
    end
  end

  defp session_id_from_ip({a, b, c, d}) do
    :crypto.hash(:sha256, "adventure-#{a}.#{b}.#{c}.#{d}") |> Base.encode16(case: :lower)
  end

  defp session_id_from_ip({a, b, c, d, e, f, g, h}) do
    :crypto.hash(:sha256, "adventure-#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}") |> Base.encode16(case: :lower)
  end

  defp session_id_from_ip(_) do
    :crypto.hash(:sha256, "adventure-default") |> Base.encode16(case: :lower)
  end

  # Get appropriate host/port based on network type (uses persistent terms for speed)
  defp get_host_port(network), do: PureGopherAi.Config.host_port(network)

  # Route selector to appropriate handler (with socket for streaming)
  defp route_selector("", host, port, network, _ip, _socket), do: root_menu(host, port, network)
  defp route_selector("/", host, port, network, _ip, _socket), do: root_menu(host, port, network)

  # AI queries (stateless) - with streaming support
  defp route_selector("/ask\t" <> query, host, port, _network, _ip, socket),
    do: AiHandler.handle_ask(query, host, port, socket)

  defp route_selector("/ask " <> query, host, port, _network, _ip, socket),
    do: AiHandler.handle_ask(query, host, port, socket)

  defp route_selector("/ask", host, port, _network, _ip, _socket),
    do: AiHandler.ask_prompt(host, port)

  # Chat (with conversation memory) - with streaming support
  defp route_selector("/chat\t" <> query, host, port, _network, client_ip, socket),
    do: AiHandler.handle_chat(query, host, port, client_ip, socket)

  defp route_selector("/chat " <> query, host, port, _network, client_ip, socket),
    do: AiHandler.handle_chat(query, host, port, client_ip, socket)

  defp route_selector("/chat", host, port, _network, _ip, _socket),
    do: AiHandler.chat_prompt(host, port)

  # Clear conversation
  defp route_selector("/clear", host, port, _network, client_ip, _socket),
    do: AiHandler.handle_clear(host, port, client_ip)

  # List available models
  defp route_selector("/models", host, port, _network, _ip, _socket),
    do: AiHandler.models_page(host, port)

  # List available personas
  defp route_selector("/personas", host, port, _network, _ip, _socket),
    do: AiHandler.personas_page(host, port)

  # Persona-specific queries (e.g., /ask-pirate, /ask-coder)
  defp route_selector("/persona-" <> rest, host, port, _network, _ip, socket) do
    case AiHandler.parse_model_query(rest) do
      {persona_id, ""} -> AiHandler.persona_ask_prompt(persona_id, host, port)
      {persona_id, query} -> AiHandler.handle_persona_ask(persona_id, query, host, port, socket)
    end
  end

  # Persona-specific chat
  defp route_selector("/chat-persona-" <> rest, host, port, _network, client_ip, socket) do
    case AiHandler.parse_model_query(rest) do
      {persona_id, ""} -> AiHandler.persona_chat_prompt(persona_id, host, port)
      {persona_id, query} -> AiHandler.handle_persona_chat(persona_id, query, host, port, client_ip, socket)
    end
  end

  # Model-specific queries (e.g., /ask-gpt2, /ask-gpt2-medium)
  defp route_selector("/ask-" <> rest, host, port, _network, _ip, socket) do
    case AiHandler.parse_model_query(rest) do
      {model_id, ""} -> AiHandler.model_ask_prompt(model_id, host, port)
      {model_id, query} -> AiHandler.handle_model_ask(model_id, query, host, port, socket)
    end
  end

  # Model-specific chat (e.g., /chat-gpt2)
  defp route_selector("/chat-" <> rest, host, port, _network, client_ip, socket) do
    case AiHandler.parse_model_query(rest) do
      {model_id, ""} -> AiHandler.model_chat_prompt(model_id, host, port)
      {model_id, query} -> AiHandler.handle_model_chat(model_id, query, host, port, client_ip, socket)
    end
  end

  # Server info
  defp route_selector("/about", host, port, network, _ip, _socket),
    do: about_page(host, port, network)

  # Server stats/metrics
  defp route_selector("/stats", host, port, _network, _ip, _socket),
    do: stats_page(host, port)

  # Health check routes
  defp route_selector("/health", host, port, _network, _ip, _socket),
    do: health_status(host, port)

  defp route_selector("/health/live", _host, _port, _network, _ip, _socket),
    do: health_live()

  defp route_selector("/health/ready", _host, _port, _network, _ip, _socket),
    do: health_ready()

  defp route_selector("/health/json", _host, _port, _network, _ip, _socket),
    do: health_json()

  # Server directory (Gopherspace links)
  defp route_selector("/servers", host, port, _network, _ip, _socket),
    do: ServerDirectory.generate_gophermap(host, port)

  # Crawler optimization
  defp route_selector("/robots.txt", host, port, _network, _ip, _socket),
    do: format_text_response(CrawlerHints.robots_txt(), host, port)

  defp route_selector("/caps.txt", host, port, _network, _ip, _socket),
    do: format_text_response(Caps.generate(), host, port)

  # Pastebin routes
  defp route_selector("/paste", host, port, _network, _ip, _socket),
    do: CommunityHandler.paste_menu(host, port)

  defp route_selector("/paste/new", host, port, _network, _ip, _socket),
    do: CommunityHandler.paste_new_prompt(host, port)

  defp route_selector("/paste/new\t" <> content, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_paste_create(content, ip, host, port)

  defp route_selector("/paste/new " <> content, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_paste_create(content, ip, host, port)

  defp route_selector("/paste/recent", host, port, _network, _ip, _socket),
    do: CommunityHandler.paste_recent(host, port)

  defp route_selector("/paste/raw/" <> id, _host, _port, _network, _ip, _socket),
    do: CommunityHandler.paste_raw(id)

  defp route_selector("/paste/" <> id, host, port, _network, _ip, _socket),
    do: CommunityHandler.paste_view(id, host, port)

  # Polls routes
  defp route_selector("/polls", host, port, _network, _ip, _socket),
    do: CommunityHandler.polls_menu(host, port)

  defp route_selector("/polls/new", host, port, _network, _ip, _socket),
    do: CommunityHandler.polls_new_prompt(host, port)

  defp route_selector("/polls/new\t" <> input, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_polls_create(input, ip, host, port)

  defp route_selector("/polls/new " <> input, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_polls_create(input, ip, host, port)

  defp route_selector("/polls/active", host, port, _network, _ip, _socket),
    do: CommunityHandler.polls_active(host, port)

  defp route_selector("/polls/closed", host, port, _network, _ip, _socket),
    do: CommunityHandler.polls_closed(host, port)

  defp route_selector("/polls/vote/" <> rest, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_polls_vote(rest, ip, host, port)

  defp route_selector("/polls/" <> id, host, port, _network, ip, _socket),
    do: CommunityHandler.polls_view(id, ip, host, port)

  # User Profiles
  defp route_selector("/users", host, port, _network, _ip, _socket),
    do: CommunityHandler.users_menu(host, port)

  defp route_selector("/users/create", host, port, _network, _ip, _socket),
    do: CommunityHandler.users_create_prompt(host, port)

  defp route_selector("/users/create\t" <> input, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_users_create(input, ip, host, port)

  defp route_selector("/users/create " <> input, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_users_create(input, ip, host, port)

  defp route_selector("/users/search", host, port, _network, _ip, _socket),
    do: CommunityHandler.users_search_prompt(host, port)

  defp route_selector("/users/search\t" <> query, host, port, _network, _ip, _socket),
    do: CommunityHandler.handle_users_search(query, host, port)

  defp route_selector("/users/search " <> query, host, port, _network, _ip, _socket),
    do: CommunityHandler.handle_users_search(query, host, port)

  defp route_selector("/users/list", host, port, _network, _ip, _socket),
    do: CommunityHandler.users_list(host, port, 1)

  defp route_selector("/users/list/page/" <> page_str, host, port, _network, _ip, _socket) do
    page = case Integer.parse(page_str) do
      {p, ""} when p > 0 -> p
      _ -> 1
    end
    CommunityHandler.users_list(host, port, page)
  end

  defp route_selector("/users/~" <> username, host, port, _network, _ip, _socket),
    do: CommunityHandler.users_view(username, host, port)

  # Calendar / Events
  defp route_selector("/calendar", host, port, _network, _ip, _socket),
    do: calendar_menu(host, port)

  defp route_selector("/calendar/upcoming", host, port, _network, _ip, _socket),
    do: calendar_upcoming(host, port)

  defp route_selector("/calendar/create", host, port, _network, _ip, _socket),
    do: calendar_create_prompt(host, port)

  defp route_selector("/calendar/create\t" <> input, host, port, _network, ip, _socket),
    do: handle_calendar_create(input, ip, host, port)

  defp route_selector("/calendar/create " <> input, host, port, _network, ip, _socket),
    do: handle_calendar_create(input, ip, host, port)

  defp route_selector("/calendar/month/" <> rest, host, port, _network, _ip, _socket) do
    case String.split(rest, "/") do
      [year_str, month_str] ->
        with {year, ""} <- Integer.parse(year_str),
             {month, ""} <- Integer.parse(month_str),
             true <- month >= 1 and month <= 12 do
          calendar_month(year, month, host, port)
        else
          _ -> error_response("Invalid month format")
        end

      _ ->
        error_response("Invalid month format. Use: /calendar/month/YYYY/MM")
    end
  end

  defp route_selector("/calendar/date/" <> date, host, port, _network, _ip, _socket),
    do: calendar_date(date, host, port)

  defp route_selector("/calendar/event/" <> id, host, port, _network, _ip, _socket),
    do: calendar_event(id, host, port)

  # URL Shortener
  defp route_selector("/short", host, port, _network, _ip, _socket),
    do: short_menu(host, port)

  defp route_selector("/short/create", host, port, _network, _ip, _socket),
    do: short_create_prompt(host, port)

  defp route_selector("/short/create\t" <> url, host, port, _network, ip, _socket),
    do: handle_short_create(url, ip, host, port)

  defp route_selector("/short/create " <> url, host, port, _network, ip, _socket),
    do: handle_short_create(url, ip, host, port)

  defp route_selector("/short/recent", host, port, _network, _ip, _socket),
    do: short_recent(host, port)

  defp route_selector("/short/info/" <> code, host, port, _network, _ip, _socket),
    do: short_info(code, host, port)

  defp route_selector("/short/" <> code, host, port, _network, _ip, _socket),
    do: short_redirect(code, host, port)

  # Quick Utilities routes
  defp route_selector("/utils", host, port, _network, _ip, _socket),
    do: utils_menu(host, port)

  defp route_selector("/utils/dice", host, port, _network, _ip, _socket),
    do: utils_dice_prompt(host, port)

  defp route_selector("/utils/dice\t" <> spec, host, port, _network, _ip, _socket),
    do: handle_dice(spec, host, port)

  defp route_selector("/utils/dice " <> spec, host, port, _network, _ip, _socket),
    do: handle_dice(spec, host, port)

  defp route_selector("/utils/8ball", host, port, _network, _ip, _socket),
    do: utils_8ball_prompt(host, port)

  defp route_selector("/utils/8ball\t" <> question, host, port, _network, _ip, _socket),
    do: handle_8ball(question, host, port)

  defp route_selector("/utils/8ball " <> question, host, port, _network, _ip, _socket),
    do: handle_8ball(question, host, port)

  defp route_selector("/utils/coin", host, port, _network, _ip, _socket),
    do: handle_coin_flip(host, port)

  defp route_selector("/utils/random", host, port, _network, _ip, _socket),
    do: utils_random_prompt(host, port)

  defp route_selector("/utils/random\t" <> range, host, port, _network, _ip, _socket),
    do: handle_random(range, host, port)

  defp route_selector("/utils/random " <> range, host, port, _network, _ip, _socket),
    do: handle_random(range, host, port)

  defp route_selector("/utils/uuid", host, port, _network, _ip, _socket),
    do: handle_uuid(host, port)

  defp route_selector("/utils/hash", host, port, _network, _ip, _socket),
    do: utils_hash_prompt(host, port)

  defp route_selector("/utils/hash\t" <> input, host, port, _network, _ip, _socket),
    do: handle_hash(input, host, port)

  defp route_selector("/utils/hash " <> input, host, port, _network, _ip, _socket),
    do: handle_hash(input, host, port)

  defp route_selector("/utils/base64/encode", host, port, _network, _ip, _socket),
    do: utils_base64_encode_prompt(host, port)

  defp route_selector("/utils/base64/encode\t" <> input, host, port, _network, _ip, _socket),
    do: handle_base64_encode(input, host, port)

  defp route_selector("/utils/base64/encode " <> input, host, port, _network, _ip, _socket),
    do: handle_base64_encode(input, host, port)

  defp route_selector("/utils/base64/decode", host, port, _network, _ip, _socket),
    do: utils_base64_decode_prompt(host, port)

  defp route_selector("/utils/base64/decode\t" <> input, host, port, _network, _ip, _socket),
    do: handle_base64_decode(input, host, port)

  defp route_selector("/utils/base64/decode " <> input, host, port, _network, _ip, _socket),
    do: handle_base64_decode(input, host, port)

  defp route_selector("/utils/rot13", host, port, _network, _ip, _socket),
    do: utils_rot13_prompt(host, port)

  defp route_selector("/utils/rot13\t" <> input, host, port, _network, _ip, _socket),
    do: handle_rot13(input, host, port)

  defp route_selector("/utils/rot13 " <> input, host, port, _network, _ip, _socket),
    do: handle_rot13(input, host, port)

  defp route_selector("/utils/password", host, port, _network, _ip, _socket),
    do: handle_password(16, host, port)

  defp route_selector("/utils/password/" <> length_str, host, port, _network, _ip, _socket) do
    length = case Integer.parse(length_str) do
      {n, ""} -> n
      _ -> 16
    end
    handle_password(length, host, port)
  end

  defp route_selector("/utils/timestamp", host, port, _network, _ip, _socket),
    do: utils_timestamp_prompt(host, port)

  defp route_selector("/utils/timestamp\t" <> ts, host, port, _network, _ip, _socket),
    do: handle_timestamp(ts, host, port)

  defp route_selector("/utils/timestamp " <> ts, host, port, _network, _ip, _socket),
    do: handle_timestamp(ts, host, port)

  defp route_selector("/utils/now", host, port, _network, _ip, _socket),
    do: handle_now(host, port)

  defp route_selector("/utils/pick", host, port, _network, _ip, _socket),
    do: utils_pick_prompt(host, port)

  defp route_selector("/utils/pick\t" <> items, host, port, _network, _ip, _socket),
    do: handle_pick(items, host, port)

  defp route_selector("/utils/pick " <> items, host, port, _network, _ip, _socket),
    do: handle_pick(items, host, port)

  defp route_selector("/utils/count", host, port, _network, _ip, _socket),
    do: utils_count_prompt(host, port)

  defp route_selector("/utils/count\t" <> text, host, port, _network, _ip, _socket),
    do: handle_count(text, host, port)

  defp route_selector("/utils/count " <> text, host, port, _network, _ip, _socket),
    do: handle_count(text, host, port)

  # Sitemap routes
  defp route_selector("/sitemap", host, port, _network, _ip, _socket),
    do: sitemap_index(host, port)

  defp route_selector("/sitemap/category/" <> category, host, port, _network, _ip, _socket),
    do: sitemap_category(category, host, port)

  defp route_selector("/sitemap/search", host, port, _network, _ip, _socket),
    do: sitemap_search_prompt(host, port)

  defp route_selector("/sitemap/search\t" <> query, host, port, _network, _ip, _socket),
    do: handle_sitemap_search(query, host, port)

  defp route_selector("/sitemap/search " <> query, host, port, _network, _ip, _socket),
    do: handle_sitemap_search(query, host, port)

  defp route_selector("/sitemap/text", host, port, _network, _ip, _socket),
    do: sitemap_text(host, port)

  # Mailbox routes
  defp route_selector("/mail", host, port, _network, _ip, _socket),
    do: mail_menu(host, port)

  defp route_selector("/mail/login", host, port, _network, _ip, _socket),
    do: mail_login_prompt(host, port)

  defp route_selector("/mail/login\t" <> username, host, port, _network, _ip, _socket),
    do: mail_inbox(username, host, port)

  defp route_selector("/mail/login " <> username, host, port, _network, _ip, _socket),
    do: mail_inbox(username, host, port)

  defp route_selector("/mail/inbox/" <> username, host, port, _network, _ip, _socket),
    do: mail_inbox_prompt(username, host, port)

  defp route_selector("/mail/sent/" <> username, host, port, _network, _ip, _socket),
    do: mail_sent_prompt(username, host, port)

  defp route_selector("/mail/read/" <> rest, host, port, _network, _ip, _socket) do
    case String.split(rest, "/", parts: 2) do
      [username, message_id] -> mail_read(username, message_id, host, port)
      _ -> error_response("Invalid message path")
    end
  end

  defp route_selector("/mail/compose/" <> username, host, port, _network, _ip, _socket),
    do: mail_compose_prompt(username, host, port)

  defp route_selector("/mail/send/" <> rest, host, port, _network, ip, _socket) do
    # Format: from_user/to_user\tsubject|body
    case String.split(rest, "/", parts: 2) do
      [from_user, to_and_content] ->
        case String.split(to_and_content, "\t", parts: 2) do
          [to_user, content] -> handle_mail_send(from_user, to_user, content, ip, host, port)
          [to_user] -> mail_compose_to_prompt(from_user, to_user, host, port)
        end
      _ ->
        error_response("Invalid send path")
    end
  end

  defp route_selector("/mail/delete/" <> rest, host, port, _network, _ip, _socket) do
    case String.split(rest, "/", parts: 2) do
      [username, message_id] -> handle_mail_delete(username, message_id, host, port)
      _ -> error_response("Invalid delete path")
    end
  end

  # Trivia / Quiz Game routes
  defp route_selector("/trivia", host, port, _network, ip, _socket),
    do: trivia_menu(session_id_from_ip(ip), host, port)

  defp route_selector("/trivia/play", host, port, _network, ip, _socket),
    do: trivia_play(session_id_from_ip(ip), nil, host, port)

  defp route_selector("/trivia/play/" <> category, host, port, _network, ip, _socket),
    do: trivia_play(session_id_from_ip(ip), category, host, port)

  defp route_selector("/trivia/answer/" <> rest, host, port, _network, ip, _socket) do
    # Handle both /trivia/answer/id/answer and /trivia/answer/id\tanswer formats
    rest = String.replace(rest, "\t", "/")
    case String.split(rest, "/", parts: 2) do
      [question_id, answer] -> trivia_answer(session_id_from_ip(ip), question_id, answer, host, port)
      [question_id] -> trivia_answer_prompt(question_id, host, port)
    end
  end

  defp route_selector("/trivia/score", host, port, _network, ip, _socket),
    do: trivia_score(session_id_from_ip(ip), host, port)

  defp route_selector("/trivia/reset", host, port, _network, ip, _socket),
    do: trivia_reset(session_id_from_ip(ip), host, port)

  defp route_selector("/trivia/leaderboard", host, port, _network, _ip, _socket),
    do: trivia_leaderboard(host, port)

  defp route_selector("/trivia/save", host, port, _network, _ip, _socket),
    do: trivia_save_prompt(host, port)

  defp route_selector("/trivia/save\t" <> nickname, host, port, _network, ip, _socket),
    do: trivia_save(session_id_from_ip(ip), nickname, host, port)

  defp route_selector("/trivia/save " <> nickname, host, port, _network, ip, _socket),
    do: trivia_save(session_id_from_ip(ip), nickname, host, port)

  # Bookmarks / Favorites routes
  defp route_selector("/bookmarks", host, port, _network, _ip, _socket),
    do: bookmarks_menu(host, port)

  defp route_selector("/bookmarks/login", host, port, _network, _ip, _socket),
    do: bookmarks_login_prompt(host, port)

  defp route_selector("/bookmarks/login\t" <> input, host, port, _network, ip, _socket),
    do: handle_bookmarks_login(input, host, port, ip)

  defp route_selector("/bookmarks/login " <> input, host, port, _network, ip, _socket),
    do: handle_bookmarks_login(input, host, port, ip)

  # Authenticated bookmark routes (include passphrase in path)
  defp route_selector("/bookmarks/user/" <> rest, host, port, _network, ip, _socket) do
    case String.split(rest, "/", parts: 3) do
      [username, passphrase, folder] -> bookmarks_user(username, passphrase, folder, host, port, ip)
      [username, passphrase] -> bookmarks_user(username, passphrase, nil, host, port, ip)
      [_username] -> bookmarks_login_redirect(host, port)
    end
  end

  defp route_selector("/bookmarks/add/" <> rest, host, port, _network, ip, _socket) do
    rest = String.replace(rest, "\t", "/")
    case String.split(rest, "/", parts: 4) do
      [username, passphrase, selector, title] -> bookmarks_add(username, passphrase, selector, title, host, port, ip)
      [username, passphrase, selector] -> bookmarks_add_title_prompt(username, passphrase, selector, host, port)
      [username, passphrase] when passphrase != "" -> bookmarks_add_prompt(username, passphrase, host, port)
      _ -> bookmarks_login_redirect(host, port)
    end
  end

  defp route_selector("/bookmarks/remove/" <> rest, host, port, _network, ip, _socket) do
    case String.split(rest, "/", parts: 3) do
      [username, passphrase, bookmark_id] -> bookmarks_remove(username, passphrase, bookmark_id, host, port, ip)
      _ -> bookmarks_login_redirect(host, port)
    end
  end

  defp route_selector("/bookmarks/folders/" <> rest, host, port, _network, ip, _socket) do
    case String.split(rest, "/", parts: 2) do
      [username, passphrase] -> bookmarks_folders(username, passphrase, host, port, ip)
      _ -> bookmarks_login_redirect(host, port)
    end
  end

  defp route_selector("/bookmarks/newfolder/" <> rest, host, port, _network, ip, _socket) do
    rest = String.replace(rest, "\t", "/")
    case String.split(rest, "/", parts: 3) do
      [username, passphrase, folder_name] -> bookmarks_create_folder(username, passphrase, folder_name, host, port, ip)
      [username, passphrase] when passphrase != "" -> bookmarks_newfolder_prompt(username, passphrase, host, port)
      _ -> bookmarks_login_redirect(host, port)
    end
  end

  defp route_selector("/bookmarks/export/" <> rest, host, port, _network, ip, _socket) do
    case String.split(rest, "/", parts: 2) do
      [username, passphrase] -> bookmarks_export(username, passphrase, host, port, ip)
      _ -> bookmarks_login_redirect(host, port)
    end
  end

  # Unit Converter routes
  defp route_selector("/convert", host, port, _network, _ip, _socket),
    do: convert_menu(host, port)

  defp route_selector("/convert/", host, port, _network, _ip, _socket),
    do: convert_menu(host, port)

  defp route_selector("/convert\t" <> query, host, port, _network, _ip, _socket),
    do: convert_query(query, host, port)

  defp route_selector("/convert " <> query, host, port, _network, _ip, _socket),
    do: convert_query(query, host, port)

  defp route_selector("/convert/" <> category, host, port, _network, _ip, _socket),
    do: convert_category(category, host, port)

  # Calculator routes
  defp route_selector("/calc", host, port, _network, _ip, _socket),
    do: calc_menu(host, port)

  defp route_selector("/calc/", host, port, _network, _ip, _socket),
    do: calc_menu(host, port)

  defp route_selector("/calc\t" <> expr, host, port, _network, _ip, _socket),
    do: calc_evaluate(expr, host, port)

  defp route_selector("/calc " <> expr, host, port, _network, _ip, _socket),
    do: calc_evaluate(expr, host, port)

  # Games routes
  defp route_selector("/games", host, port, _network, _ip, _socket),
    do: games_menu(host, port)

  defp route_selector("/games/", host, port, _network, _ip, _socket),
    do: games_menu(host, port)

  # Hangman
  defp route_selector("/games/hangman", host, port, _network, ip, _socket),
    do: hangman_start(session_id_from_ip(ip), host, port)

  defp route_selector("/games/hangman/play", host, port, _network, ip, _socket),
    do: hangman_play(session_id_from_ip(ip), host, port)

  defp route_selector("/games/hangman/guess\t" <> letter, host, port, _network, ip, _socket),
    do: hangman_guess(session_id_from_ip(ip), letter, host, port)

  defp route_selector("/games/hangman/guess " <> letter, host, port, _network, ip, _socket),
    do: hangman_guess(session_id_from_ip(ip), letter, host, port)

  # Number Guess
  defp route_selector("/games/number", host, port, _network, ip, _socket),
    do: number_guess_start(session_id_from_ip(ip), host, port)

  defp route_selector("/games/number/play", host, port, _network, ip, _socket),
    do: number_guess_play(session_id_from_ip(ip), host, port)

  defp route_selector("/games/number/guess\t" <> num, host, port, _network, ip, _socket),
    do: number_guess_guess(session_id_from_ip(ip), num, host, port)

  defp route_selector("/games/number/guess " <> num, host, port, _network, ip, _socket),
    do: number_guess_guess(session_id_from_ip(ip), num, host, port)

  # Word Scramble
  defp route_selector("/games/scramble", host, port, _network, ip, _socket),
    do: scramble_start(session_id_from_ip(ip), host, port)

  defp route_selector("/games/scramble/play", host, port, _network, ip, _socket),
    do: scramble_play(session_id_from_ip(ip), host, port)

  defp route_selector("/games/scramble/guess\t" <> word, host, port, _network, ip, _socket),
    do: scramble_guess(session_id_from_ip(ip), word, host, port)

  defp route_selector("/games/scramble/guess " <> word, host, port, _network, ip, _socket),
    do: scramble_guess(session_id_from_ip(ip), word, host, port)

  # AI Semantic Search routes
  defp route_selector("/semantic", host, port, _network, _ip, _socket),
    do: semantic_menu(host, port)

  defp route_selector("/semantic/", host, port, _network, _ip, _socket),
    do: semantic_menu(host, port)

  defp route_selector("/semantic/search", host, port, _network, _ip, _socket),
    do: semantic_search_prompt(host, port)

  defp route_selector("/semantic/search\t" <> query, host, port, _network, _ip, _socket),
    do: semantic_search(query, host, port)

  defp route_selector("/semantic/search " <> query, host, port, _network, _ip, _socket),
    do: semantic_search(query, host, port)

  defp route_selector("/semantic/similar/" <> path, host, port, _network, _ip, _socket),
    do: semantic_similar(path, host, port)

  defp route_selector("/semantic/trending", host, port, _network, _ip, _socket),
    do: semantic_trending(host, port)

  defp route_selector("/semantic/types", host, port, _network, _ip, _socket),
    do: semantic_types(host, port)

  # AI Creative Writing Studio routes
  defp route_selector("/creative", host, port, _network, _ip, _socket),
    do: creative_menu(host, port)

  defp route_selector("/creative/", host, port, _network, _ip, _socket),
    do: creative_menu(host, port)

  defp route_selector("/creative/story", host, port, _network, _ip, _socket),
    do: creative_story_prompt(host, port)

  defp route_selector("/creative/story\t" <> input, host, port, _network, _ip, _socket),
    do: creative_story(input, host, port)

  defp route_selector("/creative/story " <> input, host, port, _network, _ip, _socket),
    do: creative_story(input, host, port)

  defp route_selector("/creative/poem", host, port, _network, _ip, _socket),
    do: creative_poem_prompt(host, port)

  defp route_selector("/creative/poem\t" <> input, host, port, _network, _ip, _socket),
    do: creative_poem(input, host, port)

  defp route_selector("/creative/poem " <> input, host, port, _network, _ip, _socket),
    do: creative_poem(input, host, port)

  defp route_selector("/creative/lyrics", host, port, _network, _ip, _socket),
    do: creative_lyrics_prompt(host, port)

  defp route_selector("/creative/lyrics\t" <> input, host, port, _network, _ip, _socket),
    do: creative_lyrics(input, host, port)

  defp route_selector("/creative/lyrics " <> input, host, port, _network, _ip, _socket),
    do: creative_lyrics(input, host, port)

  defp route_selector("/creative/continue", host, port, _network, _ip, _socket),
    do: creative_continue_prompt(host, port)

  defp route_selector("/creative/continue\t" <> input, host, port, _network, _ip, _socket),
    do: creative_continue(input, host, port)

  defp route_selector("/creative/continue " <> input, host, port, _network, _ip, _socket),
    do: creative_continue(input, host, port)

  defp route_selector("/creative/rewrite/" <> style, host, port, _network, _ip, _socket),
    do: creative_rewrite_prompt(style, host, port)

  defp route_selector("/creative/prompts", host, port, _network, _ip, _socket),
    do: creative_prompts(host, port)

  defp route_selector("/creative/prompts/" <> category, host, port, _network, _ip, _socket),
    do: creative_prompts_category(category, host, port)

  defp route_selector("/creative/character", host, port, _network, _ip, _socket),
    do: creative_character_prompt(host, port)

  defp route_selector("/creative/character\t" <> input, host, port, _network, _ip, _socket),
    do: creative_character(input, host, port)

  defp route_selector("/creative/character " <> input, host, port, _network, _ip, _socket),
    do: creative_character(input, host, port)

  defp route_selector("/creative/world", host, port, _network, _ip, _socket),
    do: creative_world_prompt(host, port)

  defp route_selector("/creative/world\t" <> input, host, port, _network, _ip, _socket),
    do: creative_world(input, host, port)

  defp route_selector("/creative/world " <> input, host, port, _network, _ip, _socket),
    do: creative_world(input, host, port)

  defp route_selector("/creative/genres", host, port, _network, _ip, _socket),
    do: creative_genres(host, port)

  defp route_selector("/creative/poem-types", host, port, _network, _ip, _socket),
    do: creative_poem_types(host, port)

  defp route_selector("/creative/moods", host, port, _network, _ip, _socket),
    do: creative_moods(host, port)

  # AI Writing Assistant routes
  defp route_selector("/write", host, port, _network, _ip, _socket),
    do: write_menu(host, port)

  defp route_selector("/write/", host, port, _network, _ip, _socket),
    do: write_menu(host, port)

  defp route_selector("/write/draft", host, port, _network, _ip, _socket),
    do: write_draft_prompt(host, port)

  defp route_selector("/write/draft\t" <> input, host, port, _network, _ip, _socket),
    do: write_draft(input, host, port)

  defp route_selector("/write/draft " <> input, host, port, _network, _ip, _socket),
    do: write_draft(input, host, port)

  defp route_selector("/write/improve", host, port, _network, _ip, _socket),
    do: write_improve_prompt(host, port)

  defp route_selector("/write/improve\t" <> input, host, port, _network, _ip, _socket),
    do: write_improve(input, host, port)

  defp route_selector("/write/improve " <> input, host, port, _network, _ip, _socket),
    do: write_improve(input, host, port)

  defp route_selector("/write/proofread", host, port, _network, _ip, _socket),
    do: write_proofread_prompt(host, port)

  defp route_selector("/write/proofread\t" <> input, host, port, _network, _ip, _socket),
    do: write_proofread(input, host, port)

  defp route_selector("/write/proofread " <> input, host, port, _network, _ip, _socket),
    do: write_proofread(input, host, port)

  defp route_selector("/write/tone/" <> tone, host, port, _network, _ip, _socket),
    do: write_tone_prompt(tone, host, port)

  defp route_selector("/write/titles", host, port, _network, _ip, _socket),
    do: write_titles_prompt(host, port)

  defp route_selector("/write/titles\t" <> input, host, port, _network, _ip, _socket),
    do: write_titles(input, host, port)

  defp route_selector("/write/titles " <> input, host, port, _network, _ip, _socket),
    do: write_titles(input, host, port)

  defp route_selector("/write/tags", host, port, _network, _ip, _socket),
    do: write_tags_prompt(host, port)

  defp route_selector("/write/tags\t" <> input, host, port, _network, _ip, _socket),
    do: write_tags(input, host, port)

  defp route_selector("/write/tags " <> input, host, port, _network, _ip, _socket),
    do: write_tags(input, host, port)

  defp route_selector("/write/expand", host, port, _network, _ip, _socket),
    do: write_expand_prompt(host, port)

  defp route_selector("/write/expand\t" <> input, host, port, _network, _ip, _socket),
    do: write_expand(input, host, port)

  defp route_selector("/write/expand " <> input, host, port, _network, _ip, _socket),
    do: write_expand(input, host, port)

  defp route_selector("/write/compress", host, port, _network, _ip, _socket),
    do: write_compress_prompt(host, port)

  defp route_selector("/write/compress\t" <> input, host, port, _network, _ip, _socket),
    do: write_compress(input, host, port)

  defp route_selector("/write/compress " <> input, host, port, _network, _ip, _socket),
    do: write_compress(input, host, port)

  defp route_selector("/write/outline", host, port, _network, _ip, _socket),
    do: write_outline_prompt(host, port)

  defp route_selector("/write/outline\t" <> input, host, port, _network, _ip, _socket),
    do: write_outline(input, host, port)

  defp route_selector("/write/outline " <> input, host, port, _network, _ip, _socket),
    do: write_outline(input, host, port)

  defp route_selector("/write/intro", host, port, _network, _ip, _socket),
    do: write_intro_prompt(host, port)

  defp route_selector("/write/intro\t" <> input, host, port, _network, _ip, _socket),
    do: write_intro(input, host, port)

  defp route_selector("/write/intro " <> input, host, port, _network, _ip, _socket),
    do: write_intro(input, host, port)

  defp route_selector("/write/conclusion", host, port, _network, _ip, _socket),
    do: write_conclusion_prompt(host, port)

  defp route_selector("/write/conclusion\t" <> input, host, port, _network, _ip, _socket),
    do: write_conclusion(input, host, port)

  defp route_selector("/write/conclusion " <> input, host, port, _network, _ip, _socket),
    do: write_conclusion(input, host, port)

  defp route_selector("/write/tones", host, port, _network, _ip, _socket),
    do: write_tones_list(host, port)

  defp route_selector("/write/styles", host, port, _network, _ip, _socket),
    do: write_styles_list(host, port)

  # Terminal Slides routes
  defp route_selector("/slides", host, port, _network, _ip, _socket),
    do: slides_menu(host, port)

  defp route_selector("/slides/", host, port, _network, _ip, _socket),
    do: slides_menu(host, port)

  defp route_selector("/slides/list", host, port, _network, _ip, _socket),
    do: slides_list(host, port)

  defp route_selector("/slides/new", host, port, _network, _ip, _socket),
    do: slides_new_prompt(host, port)

  defp route_selector("/slides/new\t" <> input, host, port, _network, ip, _socket),
    do: slides_create(input, ip, host, port)

  defp route_selector("/slides/new " <> input, host, port, _network, ip, _socket),
    do: slides_create(input, ip, host, port)

  defp route_selector("/slides/view/" <> id, host, port, _network, _ip, _socket),
    do: slides_view(id, host, port)

  defp route_selector("/slides/present/" <> path, host, port, _network, _ip, _socket),
    do: slides_present(path, host, port)

  defp route_selector("/slides/edit/" <> path, host, port, _network, _ip, _socket),
    do: slides_edit(path, host, port)

  defp route_selector("/slides/add/" <> path, host, port, _network, _ip, _socket),
    do: slides_add_slide(path, host, port)

  defp route_selector("/slides/export/" <> path, host, port, _network, _ip, _socket),
    do: slides_export(path, host, port)

  defp route_selector("/slides/delete/" <> id, host, port, _network, _ip, _socket),
    do: slides_delete(id, host, port)

  defp route_selector("/slides/themes", host, port, _network, _ip, _socket),
    do: slides_themes(host, port)

  defp route_selector("/slides/templates", host, port, _network, _ip, _socket),
    do: slides_templates(host, port)

  # Phlog (Gopher blog) routes
  defp route_selector("/phlog", host, port, network, _ip, _socket),
    do: phlog_index(host, port, network, 1)

  defp route_selector("/phlog/", host, port, network, _ip, _socket),
    do: phlog_index(host, port, network, 1)

  defp route_selector("/phlog/page/" <> page_str, host, port, network, _ip, _socket) do
    page = case Integer.parse(page_str) do
      {p, ""} -> p
      _ -> 1
    end
    phlog_index(host, port, network, page)
  end

  defp route_selector("/phlog/feed", host, port, network, _ip, _socket),
    do: phlog_feed(host, port, network)

  defp route_selector("/phlog/year/" <> year_str, host, port, _network, _ip, _socket) do
    case Integer.parse(year_str) do
      {year, ""} -> phlog_year(host, port, year)
      _ -> error_response("Invalid year")
    end
  end

  defp route_selector("/phlog/month/" <> rest, host, port, _network, _ip, _socket) do
    case String.split(rest, "/", parts: 2) do
      [year_str, month_str] ->
        with {year, ""} <- Integer.parse(year_str),
             {month, ""} <- Integer.parse(month_str) do
          phlog_month(host, port, year, month)
        else
          _ -> error_response("Invalid date")
        end
      _ ->
        error_response("Invalid date format")
    end
  end

  defp route_selector("/phlog/entry/" <> entry_path, host, port, _network, _ip, _socket),
    do: phlog_entry(host, port, entry_path)

  # Phlog Comments
  defp route_selector("/phlog/comments/recent", host, port, _network, _ip, _socket),
    do: phlog_recent_comments(host, port)

  defp route_selector("/phlog/comments/" <> rest, host, port, _network, ip, _socket) do
    case String.split(rest, "/", parts: 2) do
      [entry_path, "comment"] ->
        phlog_comment_prompt(entry_path, host, port)

      [entry_path, "comment\t" <> input] ->
        handle_phlog_comment(entry_path, input, host, port, ip)

      [entry_path, "comment " <> input] ->
        handle_phlog_comment(entry_path, input, host, port, ip)

      [entry_path] ->
        phlog_view_comments(entry_path, host, port)

      _ ->
        error_response("Invalid comment path")
    end
  end

  # User Phlog (user-submitted blog posts)
  defp route_selector("/phlog/users", host, port, _network, _ip, _socket),
    do: user_phlog_authors(host, port)

  defp route_selector("/phlog/recent", host, port, _network, _ip, _socket),
    do: user_phlog_recent(host, port)

  defp route_selector("/phlog/user/" <> rest, host, port, _network, ip, _socket) do
    case String.split(rest, "/", parts: 3) do
      [username] ->
        user_phlog_list(username, host, port)

      [username, action] ->
        cond do
          action == "write" ->
            user_phlog_write_prompt(username, host, port)

          String.starts_with?(action, "write\t") ->
            input = String.replace_prefix(action, "write\t", "")
            handle_user_phlog_write(username, input, host, port, ip)

          String.starts_with?(action, "write ") ->
            input = String.replace_prefix(action, "write ", "")
            handle_user_phlog_write(username, input, host, port, ip)

          true ->
            # This is a post_id
            user_phlog_view(username, action, host, port)
        end

      [username, action, third] ->
        cond do
          action == "edit" && not String.contains?(third, "\t") && not String.contains?(third, " ") ->
            user_phlog_edit_prompt(username, third, host, port)

          action == "edit" && String.contains?(third, "\t") ->
            [post_id | rest_parts] = String.split(third, "\t", parts: 2)
            input = Enum.at(rest_parts, 0) || ""
            handle_user_phlog_edit(username, post_id, input, host, port, ip)

          action == "edit" && String.contains?(third, " ") ->
            [post_id | rest_parts] = String.split(third, " ", parts: 2)
            input = Enum.at(rest_parts, 0) || ""
            handle_user_phlog_edit(username, post_id, input, host, port, ip)

          action == "delete" && not String.contains?(third, "\t") && not String.contains?(third, " ") ->
            user_phlog_delete_prompt(username, third, host, port)

          action == "delete" && String.contains?(third, "\t") ->
            [post_id | rest_parts] = String.split(third, "\t", parts: 2)
            passphrase = Enum.at(rest_parts, 0) || ""
            handle_user_phlog_delete(username, post_id, passphrase, host, port)

          action == "delete" && String.contains?(third, " ") ->
            [post_id | rest_parts] = String.split(third, " ", parts: 2)
            passphrase = Enum.at(rest_parts, 0) || ""
            handle_user_phlog_delete(username, post_id, passphrase, host, port)

          true ->
            error_response("Invalid user phlog path")
        end

      _ ->
        error_response("Invalid user phlog path")
    end
  end

  # Phlog Formatting Tools
  defp route_selector("/phlog/format", host, port, _network, _ip, _socket),
    do: phlog_format_menu(host, port)

  defp route_selector("/phlog/format/preview", host, port, _network, _ip, _socket),
    do: phlog_format_preview_prompt(host, port)

  defp route_selector("/phlog/format/preview\t" <> input, host, port, _network, _ip, _socket),
    do: handle_phlog_format_preview(input, host, port)

  defp route_selector("/phlog/format/preview " <> input, host, port, _network, _ip, _socket),
    do: handle_phlog_format_preview(input, host, port)

  defp route_selector("/phlog/format/styles", host, port, _network, _ip, _socket),
    do: phlog_format_styles(host, port)

  defp route_selector("/phlog/format/art", host, port, _network, _ip, _socket),
    do: phlog_art_gallery(host, port)

  defp route_selector("/phlog/format/art/" <> theme, host, port, _network, _ip, _socket),
    do: phlog_art_theme(theme, host, port)

  # Color (ANSI) Art Routes
  defp route_selector("/phlog/format/color", host, port, _network, _ip, _socket),
    do: phlog_color_art_menu(host, port)

  defp route_selector("/phlog/format/color/gallery", host, port, _network, _ip, _socket),
    do: phlog_color_art_gallery(host, port)

  defp route_selector("/phlog/format/color/gallery/" <> theme, host, port, _network, _ip, _socket),
    do: phlog_color_art_theme(theme, host, port)

  defp route_selector("/phlog/format/color/preview", host, port, _network, _ip, _socket),
    do: phlog_color_preview_prompt(host, port)

  defp route_selector("/phlog/format/color/preview\t" <> input, host, port, _network, _ip, _socket),
    do: handle_phlog_color_preview(input, host, port)

  defp route_selector("/phlog/format/color/preview " <> input, host, port, _network, _ip, _socket),
    do: handle_phlog_color_preview(input, host, port)

  defp route_selector("/phlog/format/color/borders", host, port, _network, _ip, _socket),
    do: phlog_color_borders(host, port)

  # Search (Type 7)
  defp route_selector("/search", host, port, _network, _ip, _socket),
    do: ToolsHandler.search_prompt(host, port)

  defp route_selector("/search\t" <> query, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_search(query, host, port)

  defp route_selector("/search " <> query, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_search(query, host, port)

  # ASCII Art
  defp route_selector("/art", host, port, _network, _ip, _socket),
    do: ToolsHandler.art_menu(host, port)

  defp route_selector("/art/text", host, port, _network, _ip, _socket),
    do: ToolsHandler.art_text_prompt(host, port)

  defp route_selector("/art/text\t" <> text, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_art_text(text, host, port, :block)

  defp route_selector("/art/text " <> text, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_art_text(text, host, port, :block)

  defp route_selector("/art/small", host, port, _network, _ip, _socket),
    do: ToolsHandler.art_small_prompt(host, port)

  defp route_selector("/art/small\t" <> text, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_art_text(text, host, port, :small)

  defp route_selector("/art/small " <> text, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_art_text(text, host, port, :small)

  defp route_selector("/art/banner", host, port, _network, _ip, _socket),
    do: ToolsHandler.art_banner_prompt(host, port)

  defp route_selector("/art/banner\t" <> text, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_art_banner(text, host, port)

  defp route_selector("/art/banner " <> text, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_art_banner(text, host, port)

  # RAG (Document Query) routes
  defp route_selector("/docs", host, port, _network, _ip, _socket),
    do: ToolsHandler.docs_menu(host, port)

  defp route_selector("/docs/", host, port, _network, _ip, _socket),
    do: ToolsHandler.docs_menu(host, port)

  defp route_selector("/docs/list", host, port, _network, _ip, _socket),
    do: ToolsHandler.docs_list(host, port)

  defp route_selector("/docs/stats", host, port, _network, _ip, _socket),
    do: ToolsHandler.docs_stats(host, port)

  defp route_selector("/docs/ask", host, port, _network, _ip, _socket),
    do: ToolsHandler.docs_ask_prompt(host, port)

  defp route_selector("/docs/ask\t" <> query, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_docs_ask(query, host, port, socket)

  defp route_selector("/docs/ask " <> query, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_docs_ask(query, host, port, socket)

  defp route_selector("/docs/search", host, port, _network, _ip, _socket),
    do: ToolsHandler.docs_search_prompt(host, port)

  defp route_selector("/docs/search\t" <> query, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_docs_search(query, host, port)

  defp route_selector("/docs/search " <> query, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_docs_search(query, host, port)

  defp route_selector("/docs/view/" <> doc_id, host, port, _network, _ip, _socket),
    do: ToolsHandler.docs_view(doc_id, host, port)

  # === AI Services: Summarization ===

  # Phlog summarization
  defp route_selector("/summary/phlog/" <> path, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_phlog_summary(path, host, port, socket)

  # Document summarization
  defp route_selector("/summary/doc/" <> doc_id, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_doc_summary(doc_id, host, port, socket)

  # === AI Services: Translation ===

  # Translation menu
  defp route_selector("/translate", host, port, _network, _ip, _socket),
    do: ToolsHandler.translate_menu(host, port)

  # Translate phlog: /translate/<lang>/phlog/<path>
  defp route_selector("/translate/" <> rest, host, port, _network, _ip, socket) do
    ToolsHandler.handle_translate_route(rest, host, port, socket)
  end

  # === AI Services: Dynamic Content ===

  # Daily digest
  defp route_selector("/digest", host, port, _network, _ip, socket),
    do: ToolsHandler.handle_digest(host, port, socket)

  # Topic discovery
  defp route_selector("/topics", host, port, _network, _ip, socket),
    do: ToolsHandler.handle_topics(host, port, socket)

  # Content discovery/recommendations
  defp route_selector("/discover", host, port, _network, _ip, _socket),
    do: ToolsHandler.discover_prompt(host, port)

  defp route_selector("/discover\t" <> interest, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_discover(interest, host, port, socket)

  defp route_selector("/discover " <> interest, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_discover(interest, host, port, socket)

  # Explain terms
  defp route_selector("/explain", host, port, _network, _ip, _socket),
    do: ToolsHandler.explain_prompt(host, port)

  defp route_selector("/explain\t" <> term, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_explain(term, host, port, socket)

  defp route_selector("/explain " <> term, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_explain(term, host, port, socket)

  # === Gopher Proxy ===

  # Fetch external gopher content
  defp route_selector("/fetch", host, port, _network, _ip, _socket),
    do: ToolsHandler.fetch_prompt(host, port)

  defp route_selector("/fetch\t" <> url, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_fetch(url, host, port)

  defp route_selector("/fetch " <> url, host, port, _network, _ip, _socket),
    do: ToolsHandler.handle_fetch(url, host, port)

  # Fetch and summarize
  defp route_selector("/fetch-summary\t" <> url, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_fetch_summary(url, host, port, socket)

  defp route_selector("/fetch-summary " <> url, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_fetch_summary(url, host, port, socket)

  # === Guestbook ===

  defp route_selector("/guestbook", host, port, _network, _ip, _socket),
    do: CommunityHandler.guestbook_page(host, port, 1)

  defp route_selector("/guestbook/page/" <> page_str, host, port, _network, _ip, _socket) do
    page = parse_int(page_str, 1)
    CommunityHandler.guestbook_page(host, port, page)
  end

  defp route_selector("/guestbook/sign", host, port, _network, _ip, _socket),
    do: CommunityHandler.guestbook_sign_prompt(host, port)

  defp route_selector("/guestbook/sign\t" <> input, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_guestbook_sign(input, host, port, ip)

  defp route_selector("/guestbook/sign " <> input, host, port, _network, ip, _socket),
    do: CommunityHandler.handle_guestbook_sign(input, host, port, ip)

  # === Code Assistant ===

  defp route_selector("/code", host, port, _network, _ip, _socket),
    do: ToolsHandler.code_menu(host, port)

  defp route_selector("/code/languages", host, port, _network, _ip, _socket),
    do: ToolsHandler.code_languages(host, port)

  defp route_selector("/code/generate", host, port, _network, _ip, _socket),
    do: ToolsHandler.code_generate_prompt(host, port)

  defp route_selector("/code/generate\t" <> input, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_code_generate(input, host, port, socket)

  defp route_selector("/code/generate " <> input, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_code_generate(input, host, port, socket)

  defp route_selector("/code/explain", host, port, _network, _ip, _socket),
    do: ToolsHandler.code_explain_prompt(host, port)

  defp route_selector("/code/explain\t" <> input, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_code_explain(input, host, port, socket)

  defp route_selector("/code/explain " <> input, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_code_explain(input, host, port, socket)

  defp route_selector("/code/review", host, port, _network, _ip, _socket),
    do: ToolsHandler.code_review_prompt(host, port)

  defp route_selector("/code/review\t" <> input, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_code_review(input, host, port, socket)

  defp route_selector("/code/review " <> input, host, port, _network, _ip, socket),
    do: ToolsHandler.handle_code_review(input, host, port, socket)

  # === Text Adventure ===

  defp route_selector("/adventure", host, port, _network, ip, _socket),
    do: adventure_menu(host, port, ip)

  defp route_selector("/adventure/new", host, port, _network, _ip, _socket),
    do: adventure_genres(host, port)

  defp route_selector("/adventure/new/" <> genre, host, port, _network, ip, socket),
    do: handle_adventure_new(genre, host, port, ip, socket)

  defp route_selector("/adventure/action", host, port, _network, _ip, _socket),
    do: adventure_action_prompt(host, port)

  defp route_selector("/adventure/action\t" <> action, host, port, _network, ip, socket),
    do: handle_adventure_action(action, host, port, ip, socket)

  defp route_selector("/adventure/action " <> action, host, port, _network, ip, socket),
    do: handle_adventure_action(action, host, port, ip, socket)

  defp route_selector("/adventure/look", host, port, _network, ip, _socket),
    do: adventure_look(host, port, ip)

  defp route_selector("/adventure/inventory", host, port, _network, ip, _socket),
    do: adventure_inventory(host, port, ip)

  defp route_selector("/adventure/stats", host, port, _network, ip, _socket),
    do: adventure_stats(host, port, ip)

  defp route_selector("/adventure/save", host, port, _network, ip, _socket),
    do: adventure_save(host, port, ip)

  defp route_selector("/adventure/load", host, port, _network, _ip, _socket),
    do: adventure_load_prompt(host, port)

  defp route_selector("/adventure/load\t" <> code, host, port, _network, ip, _socket),
    do: handle_adventure_load(code, host, port, ip)

  defp route_selector("/adventure/load " <> code, host, port, _network, ip, _socket),
    do: handle_adventure_load(code, host, port, ip)

  # === RSS/Atom Feed Aggregator ===

  defp route_selector("/feeds", host, port, _network, _ip, _socket),
    do: feeds_menu(host, port)

  defp route_selector("/feeds/digest", host, port, _network, _ip, socket),
    do: feeds_digest(host, port, socket)

  defp route_selector("/feeds/opml", host, port, _network, _ip, _socket),
    do: feeds_opml(host, port)

  defp route_selector("/feeds/stats", host, port, _network, _ip, _socket),
    do: feeds_stats(host, port)

  defp route_selector("/feeds/" <> rest, host, port, _network, _ip, _socket),
    do: handle_feed_route(rest, host, port)

  # === Weather Service ===

  defp route_selector("/weather", host, port, _network, _ip, _socket),
    do: weather_prompt(host, port)

  defp route_selector("/weather\t" <> location, host, port, _network, _ip, socket),
    do: handle_weather(location, host, port, socket)

  defp route_selector("/weather " <> location, host, port, _network, _ip, socket),
    do: handle_weather(location, host, port, socket)

  defp route_selector("/weather/forecast\t" <> location, host, port, _network, _ip, socket),
    do: handle_weather_forecast(location, host, port, socket)

  defp route_selector("/weather/forecast " <> location, host, port, _network, _ip, socket),
    do: handle_weather_forecast(location, host, port, socket)

  # Fortune/Quote routes
  defp route_selector("/fortune", host, port, _network, _ip, _socket),
    do: fortune_menu(host, port)

  defp route_selector("/fortune/random", host, port, _network, _ip, _socket),
    do: handle_fortune_random(host, port)

  defp route_selector("/fortune/today", host, port, _network, _ip, _socket),
    do: handle_fortune_of_day(host, port)

  defp route_selector("/fortune/cookie", host, port, _network, _ip, _socket),
    do: handle_fortune_cookie(host, port)

  defp route_selector("/fortune/category/" <> category, host, port, _network, _ip, _socket),
    do: handle_fortune_category(category, host, port)

  defp route_selector("/fortune/interpret", host, port, _network, _ip, _socket),
    do: fortune_interpret_prompt(host, port)

  defp route_selector("/fortune/interpret\t" <> quote, host, port, _network, _ip, socket),
    do: handle_fortune_interpret(quote, host, port, socket)

  defp route_selector("/fortune/interpret " <> quote, host, port, _network, _ip, socket),
    do: handle_fortune_interpret(quote, host, port, socket)

  defp route_selector("/fortune/search", host, port, _network, _ip, _socket),
    do: fortune_search_prompt(host, port)

  defp route_selector("/fortune/search\t" <> keyword, host, port, _network, _ip, _socket),
    do: handle_fortune_search(keyword, host, port)

  defp route_selector("/fortune/search " <> keyword, host, port, _network, _ip, _socket),
    do: handle_fortune_search(keyword, host, port)

  # Link Directory routes
  defp route_selector("/links", host, port, _network, _ip, _socket),
    do: links_menu(host, port)

  defp route_selector("/links/category/" <> category, host, port, _network, _ip, _socket),
    do: handle_links_category(category, host, port)

  defp route_selector("/links/submit", host, port, _network, _ip, _socket),
    do: links_submit_prompt(host, port)

  defp route_selector("/links/submit\t" <> input, host, port, _network, ip, _socket),
    do: handle_links_submit(input, host, port, ip)

  defp route_selector("/links/submit " <> input, host, port, _network, ip, _socket),
    do: handle_links_submit(input, host, port, ip)

  defp route_selector("/links/search", host, port, _network, _ip, _socket),
    do: links_search_prompt(host, port)

  defp route_selector("/links/search\t" <> query, host, port, _network, _ip, _socket),
    do: handle_links_search(query, host, port)

  defp route_selector("/links/search " <> query, host, port, _network, _ip, _socket),
    do: handle_links_search(query, host, port)

  # Bulletin Board routes
  defp route_selector("/board", host, port, _network, _ip, _socket),
    do: board_menu(host, port)

  defp route_selector("/board/recent", host, port, _network, _ip, _socket),
    do: handle_board_recent(host, port)

  defp route_selector("/board/" <> rest, host, port, _network, _ip, _socket) do
    case String.split(rest, "/", parts: 3) do
      [board_id] ->
        handle_board_list(board_id, host, port)

      [board_id, "new"] ->
        board_new_thread_prompt(board_id, host, port)

      [board_id, "thread", thread_id] ->
        handle_board_thread(board_id, thread_id, host, port)

      [board_id, "reply", thread_id] ->
        board_reply_prompt(board_id, thread_id, host, port)

      _ ->
        error_response("Invalid board path")
    end
  end

  defp route_selector("/board-new\t" <> input, host, port, _network, ip, _socket),
    do: handle_board_new_thread(input, host, port, ip)

  defp route_selector("/board-new " <> input, host, port, _network, ip, _socket),
    do: handle_board_new_thread(input, host, port, ip)

  defp route_selector("/board-reply\t" <> input, host, port, _network, ip, _socket),
    do: handle_board_reply(input, host, port, ip)

  defp route_selector("/board-reply " <> input, host, port, _network, ip, _socket),
    do: handle_board_reply(input, host, port, ip)

  # === Auth / Session Routes ===

  defp route_selector("/auth", host, port, _network, _ip, _socket),
    do: SecurityHandler.session_menu(host, port)

  defp route_selector("/auth/login", host, port, _network, _ip, _socket),
    do: SecurityHandler.login_prompt(host, port)

  defp route_selector("/auth/login\t" <> input, host, port, _network, ip, _socket),
    do: SecurityHandler.handle_login(input, ip, host, port)

  defp route_selector("/auth/login " <> input, host, port, _network, ip, _socket),
    do: SecurityHandler.handle_login(input, ip, host, port)

  defp route_selector("/auth/logout/" <> token, host, port, _network, ip, _socket),
    do: SecurityHandler.handle_logout(token, ip, host, port)

  defp route_selector("/auth/validate\t" <> token, host, port, _network, ip, _socket),
    do: SecurityHandler.handle_validate(token, ip, host, port)

  defp route_selector("/auth/validate " <> token, host, port, _network, ip, _socket),
    do: SecurityHandler.handle_validate(token, ip, host, port)

  defp route_selector("/auth/refresh/" <> token, host, port, _network, ip, _socket),
    do: SecurityHandler.handle_refresh(token, ip, host, port)

  # CAPTCHA routes
  defp route_selector("/captcha/verify/" <> rest, host, port, _network, _ip, _socket) do
    case String.split(rest, "/", parts: 3) do
      [action, challenge_id, encoded_return] ->
        # Extract response from tab-separated input
        {encoded_return, response} = case String.split(encoded_return, "\t", parts: 2) do
          [enc, resp] -> {enc, resp}
          [enc] -> {enc, ""}
        end
        SecurityHandler.handle_captcha_verify(action, challenge_id, encoded_return, response, host, port)
      _ ->
        error_response("Invalid CAPTCHA path")
    end
  end

  defp route_selector("/captcha/new/" <> rest, host, port, _network, _ip, _socket) do
    case String.split(rest, "/", parts: 2) do
      [action, encoded_return] ->
        SecurityHandler.handle_new_captcha(action, encoded_return, host, port)
      _ ->
        error_response("Invalid CAPTCHA path")
    end
  end

  # Admin routes (token-authenticated)
  defp route_selector("/admin/" <> rest, host, port, _network, _ip, _socket) do
    AdminHandler.handle_admin(rest, host, port)
  end

  # Static content via gophermap
  defp route_selector("/files" <> rest, host, port, _network, _ip, _socket),
    do: serve_static(rest, host, port)

  # Catch-all: check gophermap content, then error
  defp route_selector(selector, host, port, _network, _ip, _socket) do
    # Try to serve from gophermap content directory
    if Gophermap.exists?(selector) do
      case Gophermap.serve(selector, host, port) do
        {:ok, content} -> content
        {:error, _} -> error_response("Failed to serve: #{selector}")
      end
    else
      error_response("Unknown selector: #{selector}")
    end
  end

  # Root menu - Gopher type 1 (directory)
  defp root_menu(host, port, network) do
    network_banner =
      case network do
        :tor -> "Tor Hidden Service"
        :clearnet -> "Clearnet"
      end

    content_dir = Gophermap.content_dir()
    has_files = File.exists?(content_dir) and File.dir?(content_dir)

    files_section =
      if has_files do
        "1Browse Files\t/files\t#{host}\t#{port}\r\n"
      else
        ""
      end

    """
    iWelcome to PureGopherAI Server\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPowered by Elixir + Bumblebee + Metal GPU\t\t#{host}\t#{port}
    iNetwork: #{network_banner}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i=== AI Services ===\t\t#{host}\t#{port}
    7Ask AI (single query)\t/ask\t#{host}\t#{port}
    7Chat (with memory)\t/chat\t#{host}\t#{port}
    0Clear conversation\t/clear\t#{host}\t#{port}
    1Browse AI Models\t/models\t#{host}\t#{port}
    1Browse AI Personas\t/personas\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i=== AI Tools ===\t\t#{host}\t#{port}
    1Code Assistant\t/code\t#{host}\t#{port}
    7Weather\t/weather\t#{host}\t#{port}
    0Daily Digest\t/digest\t#{host}\t#{port}
    0Topic Discovery\t/topics\t#{host}\t#{port}
    7Content Recommendations\t/discover\t#{host}\t#{port}
    7Explain a Term\t/explain\t#{host}\t#{port}
    1Translation Service\t/translate\t#{host}\t#{port}
    1Gopher Proxy\t/fetch\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i=== Content ===\t\t#{host}\t#{port}
    7Search Content\t/search\t#{host}\t#{port}
    1Document Knowledge Base\t/docs\t#{host}\t#{port}
    1Phlog (Blog)\t/phlog\t#{host}\t#{port}
    1RSS/Atom Feeds\t/feeds\t#{host}\t#{port}
    1ASCII Art Generator\t/art\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i=== Community ===\t\t#{host}\t#{port}
    1Guestbook\t/guestbook\t#{host}\t#{port}
    1Text Adventure\t/adventure\t#{host}\t#{port}
    1Fortune & Quotes\t/fortune\t#{host}\t#{port}
    1Link Directory\t/links\t#{host}\t#{port}
    1Bulletin Board\t/board\t#{host}\t#{port}
    1Pastebin\t/paste\t#{host}\t#{port}
    1Polls & Voting\t/polls\t#{host}\t#{port}
    1User Profiles\t/users\t#{host}\t#{port}
    1Calendar & Events\t/calendar\t#{host}\t#{port}
    1URL Shortener\t/short\t#{host}\t#{port}
    1Quick Utilities\t/utils\t#{host}\t#{port}
    1Mailbox\t/mail\t#{host}\t#{port}
    1Trivia Quiz\t/trivia\t#{host}\t#{port}
    1Bookmarks\t/bookmarks\t#{host}\t#{port}
    7Unit Converter\t/convert\t#{host}\t#{port}
    7Calculator\t/calc\t#{host}\t#{port}
    1Games\t/games\t#{host}\t#{port}
    #{files_section}i\t\t#{host}\t#{port}
    i=== Server ===\t\t#{host}\t#{port}
    0About this server\t/about\t#{host}\t#{port}
    0Server statistics\t/stats\t#{host}\t#{port}
    0Health check\t/health\t#{host}\t#{port}
    1Gopherspace Directory\t/servers\t#{host}\t#{port}
    1Full Sitemap\t/sitemap\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTip: /summary/phlog/<path> for TL;DR summaries\t\t#{host}\t#{port}
    .
    """
  end

  # Serve static files via gophermap
  defp serve_static(path, host, port) do
    # Normalize path
    normalized = if path == "" or path == "/", do: "", else: path

    case Gophermap.serve(normalized, host, port) do
      {:ok, content} ->
        content

      {:error, :not_found} ->
        error_response("File not found: #{path}")

      {:error, reason} ->
        error_response("Error serving file: #{sanitize_error(reason)}")
    end
  end

  # About page - server stats
  defp about_page(host, port, network) do
    {:ok, hostname} = :inet.gethostname()
    memory = :erlang.memory()
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)
    uptime_min = div(uptime_ms, 60_000)

    backend_info =
      case :os.type() do
        {:unix, :darwin} -> "Torchx (Metal MPS GPU)"
        _ -> "EXLA (CPU)"
      end

    network_info =
      case network do
        :tor -> "Tor Hidden Service (port 70)"
        :clearnet -> "Clearnet (port #{port})"
      end

    content_dir = Gophermap.content_dir()
    content_status = if File.exists?(content_dir), do: "Active", else: "Not configured"

    # Get cache stats
    cache_stats = PureGopherAi.ResponseCache.stats()
    cache_status = if cache_stats.enabled, do: "Enabled", else: "Disabled"

    format_text_response(
      """
      === PureGopherAI Server Stats ===

      Host: #{hostname}
      Network: #{network_info}
      Protocol: Gopher (RFC 1436)

      Runtime: Elixir #{System.version()} / OTP #{System.otp_release()}
      Uptime: #{uptime_min} minutes
      Memory (Total): #{div(memory[:total], 1_048_576)} MB
      Memory (Processes): #{div(memory[:processes], 1_048_576)} MB

      AI Backend: Bumblebee
      Compute Backend: #{backend_info}
      Model: GPT-2 (openai-community/gpt2)

      Response Cache: #{cache_status}
      Cache Size: #{cache_stats.size}/#{cache_stats.max_size}
      Cache Hit Rate: #{cache_stats.hit_rate}%
      Cache Hits/Misses: #{cache_stats.hits}/#{cache_stats.misses}

      Content Directory: #{content_dir}
      Content Status: #{content_status}

      TCP Server: ThousandIsland
      Architecture: OTP Supervision Tree
      """,
      host,
      port
    )
  end

  # Stats page - detailed metrics
  defp stats_page(host, port) do
    stats = Telemetry.format_stats()
    cache_stats = PureGopherAi.ResponseCache.stats()

    format_text_response(
      """
      === PureGopherAI Server Metrics ===

      --- Request Statistics ---
      Total Requests: #{stats.total_requests}
      Requests/Hour: #{stats.requests_per_hour}
      Uptime: #{stats.uptime_hours} hours

      --- By Network ---
      Clearnet: #{stats.clearnet_requests}
      Tor: #{stats.tor_requests}

      --- By Type ---
      AI Queries (/ask): #{stats.ask_requests}
      Chat (/chat): #{stats.chat_requests}
      Static Content: #{stats.static_requests}

      --- Performance ---
      Avg Latency: #{stats.avg_latency_ms}ms
      Max Latency: #{stats.max_latency_ms}ms

      --- Errors ---
      Total Errors: #{stats.total_errors}
      Error Rate: #{stats.error_rate}%

      --- Cache ---
      Status: #{if cache_stats.enabled, do: "Enabled", else: "Disabled"}
      Size: #{cache_stats.size}/#{cache_stats.max_size}
      Hit Rate: #{cache_stats.hit_rate}%
      Hits: #{cache_stats.hits}
      Misses: #{cache_stats.misses}
      Writes: #{cache_stats.writes}
      """,
      host,
      port
    )
  end

  # === Health Check Functions ===

  defp health_status(host, port) do
    format_text_response(HealthCheck.status_text(), host, port)
  end

  defp health_live do
    case HealthCheck.live() do
      :ok -> "OK\r\n"
      _ -> "FAIL\r\n"
    end
  end

  defp health_ready do
    case HealthCheck.ready() do
      :ok -> "OK\r\n"
      {:error, reasons} when is_list(reasons) ->
        # Sanitize to just show which components failed, not internal details
        failed = reasons |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
        "FAIL: #{failed}\r\n"
      {:error, _reasons} -> "FAIL: service unavailable\r\n"
    end
  end

  defp health_json do
    HealthCheck.status_json() <> "\r\n"
  end

  # === Phlog Functions ===

  # Phlog index page with pagination
  defp phlog_index(host, port, network, page) do
    phlog_dir = Phlog.content_dir()

    if not File.dir?(phlog_dir) do
      phlog_empty_page(host, port)
    else
      result = Phlog.list_entries(page)

      if result.total_entries == 0 do
        phlog_empty_page(host, port)
      else
        years = Phlog.list_years()

        entry_lines =
          result.entries
          |> Enum.map(fn {date, title, path} ->
            "0[#{date}] #{title}\t/phlog/entry/#{path}\t#{host}\t#{port}\r\n"
          end)
          |> Enum.join("")

        year_lines =
          years
          |> Enum.map(fn year ->
            "1Browse #{year}\t/phlog/year/#{year}\t#{host}\t#{port}\r\n"
          end)
          |> Enum.join("")

        prev_link =
          if result.page > 1 do
            "1← Previous Page\t/phlog/page/#{result.page - 1}\t#{host}\t#{port}\r\n"
          else
            ""
          end

        next_link =
          if result.page < result.total_pages do
            "1Next Page →\t/phlog/page/#{result.page + 1}\t#{host}\t#{port}\r\n"
          else
            ""
          end

        _base_url = phlog_base_url(host, port, network)

        """
        i=== PureGopherAI Phlog ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iPage #{result.page} of #{result.total_pages} (#{result.total_entries} entries)\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i--- Recent Entries ---\t\t#{host}\t#{port}
        #{entry_lines}i\t\t#{host}\t#{port}
        #{prev_link}#{next_link}i\t\t#{host}\t#{port}
        i--- Browse by Year ---\t\t#{host}\t#{port}
        #{year_lines}i\t\t#{host}\t#{port}
        0Atom Feed\t/phlog/feed\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Main Menu\t/\t#{host}\t#{port}
        .
        """
      end
    end
  end

  defp phlog_empty_page(host, port) do
    """
    i=== PureGopherAI Phlog ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iNo phlog entries yet.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTo add entries, create text files in:\t\t#{host}\t#{port}
    i  #{Phlog.content_dir()}/YYYY/MM/DD-title.txt\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  # Phlog entries by year
  defp phlog_year(host, port, year) do
    entries = Phlog.entries_by_year(year)
    months = Phlog.list_months(year)

    if Enum.empty?(entries) do
      """
      i=== Phlog: #{year} ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      iNo entries for #{year}.\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1Back to Phlog\t/phlog\t#{host}\t#{port}
      .
      """
    else
      month_lines =
        months
        |> Enum.map(fn month ->
          month_name = month_name(String.to_integer(month))
          "1#{month_name} #{year}\t/phlog/month/#{year}/#{month}\t#{host}\t#{port}\r\n"
        end)
        |> Enum.join("")

      entry_lines =
        entries
        |> Enum.take(20)
        |> Enum.map(fn {date, title, path} ->
          "0[#{date}] #{title}\t/phlog/entry/#{path}\t#{host}\t#{port}\r\n"
        end)
        |> Enum.join("")

      """
      i=== Phlog: #{year} ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      i#{length(entries)} entries\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      i--- Browse by Month ---\t\t#{host}\t#{port}
      #{month_lines}i\t\t#{host}\t#{port}
      i--- All Entries ---\t\t#{host}\t#{port}
      #{entry_lines}i\t\t#{host}\t#{port}
      1Back to Phlog\t/phlog\t#{host}\t#{port}
      .
      """
    end
  end

  # Phlog entries by month
  defp phlog_month(host, port, year, month) do
    entries = Phlog.entries_by_month(year, month)
    month_name = month_name(month)

    if Enum.empty?(entries) do
      """
      i=== Phlog: #{month_name} #{year} ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      iNo entries for #{month_name} #{year}.\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1Back to #{year}\t/phlog/year/#{year}\t#{host}\t#{port}
      1Back to Phlog\t/phlog\t#{host}\t#{port}
      .
      """
    else
      entry_lines =
        entries
        |> Enum.map(fn {date, title, path} ->
          "0[#{date}] #{title}\t/phlog/entry/#{path}\t#{host}\t#{port}\r\n"
        end)
        |> Enum.join("")

      """
      i=== Phlog: #{month_name} #{year} ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      i#{length(entries)} entries\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      #{entry_lines}i\t\t#{host}\t#{port}
      1Back to #{year}\t/phlog/year/#{year}\t#{host}\t#{port}
      1Back to Phlog\t/phlog\t#{host}\t#{port}
      .
      """
    end
  end

  # Phlog single entry
  defp phlog_entry(host, port, entry_path) do
    case Phlog.get_entry(entry_path) do
      {:ok, entry} ->
        comment_count = PhlogComments.count_comments(entry_path)
        comment_text = if comment_count == 1, do: "1 comment", else: "#{comment_count} comments"

        """
        i=== #{entry.title} ===\t\t#{host}\t#{port}
        iDate: #{entry.date}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{entry.content |> String.split("\n") |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end) |> Enum.join("\r\n")}
        i\t\t#{host}\t#{port}
        i---\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1View Comments (#{comment_text})\t/phlog/comments/#{entry_path}\t#{host}\t#{port}
        7Add Comment\t/phlog/comments/#{entry_path}/comment\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """

      {:error, :invalid_path} ->
        error_response("Invalid phlog path")

      {:error, _} ->
        error_response("Phlog entry not found: #{entry_path}")
    end
  end

  # Phlog Comments handlers
  defp phlog_view_comments(entry_path, host, port) do
    case PhlogComments.get_comments(entry_path, order: :desc) do
      {:ok, comments} ->
        header = """
        i=== Comments for #{entry_path} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        """

        comments_text = if Enum.empty?(comments) do
          "iNo comments yet. Be the first to comment!\t\t#{host}\t#{port}\r\n"
        else
          comments
          |> Enum.map(fn c ->
            date = format_date(c.created_at)
            """
            i--- #{c.author} (#{date}) ---\t\t#{host}\t#{port}
            #{c.message |> String.split("\n") |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end) |> Enum.join("\r\n")}
            i\t\t#{host}\t#{port}
            """
          end)
          |> Enum.join("")
        end

        footer = """
        7Add Comment\t/phlog/comments/#{entry_path}/comment\t#{host}\t#{port}
        1Back to Entry\t/phlog/entry/#{entry_path}\t#{host}\t#{port}
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """

        header <> comments_text <> footer

      {:error, _} ->
        error_response("Could not load comments")
    end
  end

  defp phlog_comment_prompt(entry_path, host, port) do
    """
    7Leave a comment on #{entry_path}\t/phlog/comments/#{entry_path}/comment\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: Name | Your message here\t\t#{host}\t#{port}
    iExample: Alice | Great post, thanks!\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_phlog_comment(entry_path, input, host, port, ip) do
    case String.split(input, "|", parts: 2) do
      [author, message] ->
        case PhlogComments.add_comment(entry_path, String.trim(author), String.trim(message), ip) do
          {:ok, _id} ->
            """
            i=== Comment Posted! ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iThank you for your comment!\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1View Comments\t/phlog/comments/#{entry_path}\t#{host}\t#{port}
            1Back to Entry\t/phlog/entry/#{entry_path}\t#{host}\t#{port}
            .
            """

          {:error, :rate_limited} ->
            error_response("Please wait before commenting again")

          {:error, :empty_author} ->
            error_response("Please provide your name")

          {:error, :empty_message} ->
            error_response("Please provide a message")

          {:error, :author_too_long} ->
            error_response("Name is too long (max 50 characters)")

          {:error, :message_too_long} ->
            error_response("Message is too long (max 1000 characters)")

          {:error, :too_many_comments} ->
            error_response("Maximum comments reached for this entry")

          {:error, _} ->
            error_response("Could not post comment")
        end

      _ ->
        error_response("Invalid format. Use: Name | Your message")
    end
  end

  defp phlog_recent_comments(host, port) do
    case PhlogComments.recent_comments(20) do
      {:ok, comments} ->
        header = """
        i=== Recent Phlog Comments ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        """

        comments_text = if Enum.empty?(comments) do
          "iNo comments yet.\t\t#{host}\t#{port}\r\n"
        else
          comments
          |> Enum.map(fn c ->
            date = format_date(c.created_at)
            preview = c.message |> String.slice(0, 60) |> String.replace("\n", " ")
            preview = if String.length(c.message) > 60, do: preview <> "...", else: preview
            """
            i#{c.author} on #{c.entry_path} (#{date})\t\t#{host}\t#{port}
            i  \"#{preview}\"\t\t#{host}\t#{port}
            1  View full comment\t/phlog/comments/#{c.entry_path}\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            """
          end)
          |> Enum.join("")
        end

        footer = """
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """

        header <> comments_text <> footer

      {:error, _} ->
        error_response("Could not load recent comments")
    end
  end

  # Phlog Atom feed
  defp phlog_feed(host, port, network) do
    base_url = phlog_base_url(host, port, network)
    feed = Phlog.generate_atom_feed(base_url, title: "PureGopherAI Phlog")
    feed
  end

  defp phlog_base_url(host, port, network) do
    case network do
      :tor -> "gopher://#{host}"
      :clearnet when port == 70 -> "gopher://#{host}"
      :clearnet -> "gopher://#{host}:#{port}"
    end
  end

  defp month_name(month) do
    case month do
      1 -> "January"
      2 -> "February"
      3 -> "March"
      4 -> "April"
      5 -> "May"
      6 -> "June"
      7 -> "July"
      8 -> "August"
      9 -> "September"
      10 -> "October"
      11 -> "November"
      12 -> "December"
      _ -> "Unknown"
    end
  end

  # Note: Search, Art, Docs, Translate, Summary, AI Services, Gopher Proxy, Guestbook, and Code functions
  # have been moved to handlers/tools.ex and handlers/community.ex

  # === Adventure Functions ===

  defp adventure_menu(host, port, ip) do
    session_id = session_id_from_ip(ip)

    case Adventure.get_session(session_id) do
      {:ok, state} ->
        # Has an active game
        """
        i=== Text Adventure ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iCurrent Game: #{state.genre_name}\t\t#{host}\t#{port}
        iTurn: #{state.turn}\t\t#{host}\t#{port}
        iHealth: #{state.stats.health}/100\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Continue Adventure\t/adventure/look\t#{host}\t#{port}
        7Take Action\t/adventure/action\t#{host}\t#{port}
        1View Inventory\t/adventure/inventory\t#{host}\t#{port}
        1View Stats\t/adventure/stats\t#{host}\t#{port}
        0Save Game\t/adventure/save\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/adventure/new\t#{host}\t#{port}
        7Load Saved Game\t/adventure/load\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Home\t/\t#{host}\t#{port}
        .
        """
      {:error, :not_found} ->
        # No active game
        """
        i=== Text Adventure ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iEmbark on an AI-powered adventure!\t\t#{host}\t#{port}
        iChoose your genre and let the story unfold.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/adventure/new\t#{host}\t#{port}
        7Load Saved Game\t/adventure/load\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Home\t/\t#{host}\t#{port}
        .
        """
    end
  end

  defp adventure_genres(host, port) do
    genres = Adventure.genres()

    header = """
    i=== Choose Your Adventure ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSelect a genre to begin your journey:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    """

    genre_lines = genres
      |> Enum.map(fn {key, %{name: name, description: desc}} ->
        "1#{name} - #{desc}\t/adventure/new/#{key}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    footer = """
    i\t\t#{host}\t#{port}
    1Back\t/adventure\t#{host}\t#{port}
    .
    """

    header <> genre_lines <> "\r\n" <> footer
  end

  defp handle_adventure_new(genre, host, port, ip, socket) do
    session_id = session_id_from_ip(ip)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      genre_info = Adventure.genres()[genre] || Adventure.genres()["fantasy"]

      header = format_gopher_lines([
        "=== New Adventure: #{genre_info.name} ===",
        "",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      Adventure.new_game_stream(session_id, genre, fn chunk ->
        if String.length(chunk) > 0 do
          lines = String.split(chunk, "\n", trim: false)
          formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
          ThousandIsland.Socket.send(socket, Enum.join(formatted))
        end
      end)

      elapsed = System.monotonic_time(:millisecond) - start_time
      footer = format_gopher_lines([
        "",
        "---",
        "Adventure started in #{elapsed}ms"
      ], host, port) <>
        "i\t\t#{host}\t#{port}\r\n" <>
        "7Take Action\t/adventure/action\t#{host}\t#{port}\r\n" <>
        "1View Inventory\t/adventure/inventory\t#{host}\t#{port}\r\n" <>
        "1Adventure Menu\t/adventure\t#{host}\t#{port}\r\n"

      ThousandIsland.Socket.send(socket, footer <> ".\r\n")
      :streamed
    else
      case Adventure.new_game(session_id, genre) do
        {:ok, state, intro} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          format_text_response("""
          === New Adventure: #{state.genre_name} ===

          #{intro}

          ---
          Adventure started in #{elapsed}ms
          """, host, port) <>
            "i\t\t#{host}\t#{port}\r\n" <>
            "7Take Action\t/adventure/action\t#{host}\t#{port}\r\n" <>
            "1View Inventory\t/adventure/inventory\t#{host}\t#{port}\r\n" <>
            "1Adventure Menu\t/adventure\t#{host}\t#{port}\r\n" <>
            ".\r\n"

        {:error, reason} ->
          error_response("Failed to start adventure: #{sanitize_error(reason)}")
      end
    end
  end

  defp adventure_action_prompt(host, port) do
    """
    i=== Take Action ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iWhat do you do?\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i- Look around the room\t\t#{host}\t#{port}
    i- Attack the goblin\t\t#{host}\t#{port}
    i- Pick up the key\t\t#{host}\t#{port}
    i- Talk to the merchant\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter your action:\t/adventure/action\t#{host}\t#{port}
    .
    """
  end

  defp handle_adventure_action(action, host, port, ip, socket) do
    session_id = session_id_from_ip(ip)
    action = String.trim(action)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      header = format_gopher_lines([
        "=== Adventure ===",
        "",
        "> #{action}",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      case Adventure.take_action_stream(session_id, action, fn chunk ->
        if String.length(chunk) > 0 do
          lines = String.split(chunk, "\n", trim: false)
          formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
          ThousandIsland.Socket.send(socket, Enum.join(formatted))
        end
      end) do
        {:ok, state, _response} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          status = if state.alive do
            "Health: #{state.stats.health}/100 | Turn #{state.turn}"
          else
            "*** GAME OVER ***"
          end

          footer = format_gopher_lines([
            "",
            "---",
            status,
            "#{elapsed}ms"
          ], host, port) <>
            "i\t\t#{host}\t#{port}\r\n" <>
            "7Take Action\t/adventure/action\t#{host}\t#{port}\r\n" <>
            "1View Inventory\t/adventure/inventory\t#{host}\t#{port}\r\n" <>
            "1Adventure Menu\t/adventure\t#{host}\t#{port}\r\n"

          ThousandIsland.Socket.send(socket, footer <> ".\r\n")

        {:error, :no_game} ->
          ThousandIsland.Socket.send(socket,
            "i\t\t#{host}\t#{port}\r\n" <>
            "iNo active game. Start a new adventure!\t\t#{host}\t#{port}\r\n" <>
            "1Start New Game\t/adventure/new\t#{host}\t#{port}\r\n" <>
            ".\r\n"
          )

        {:error, :game_over} ->
          ThousandIsland.Socket.send(socket,
            "i\t\t#{host}\t#{port}\r\n" <>
            "i*** GAME OVER ***\t\t#{host}\t#{port}\r\n" <>
            "1Start New Game\t/adventure/new\t#{host}\t#{port}\r\n" <>
            ".\r\n"
          )

        {:error, reason} ->
          ThousandIsland.Socket.send(socket,
            "iError: #{sanitize_error(reason)}\t\t#{host}\t#{port}\r\n.\r\n"
          )
      end

      :streamed
    else
      case Adventure.take_action(session_id, action) do
        {:ok, state, response} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          status = if state.alive do
            "Health: #{state.stats.health}/100 | Turn #{state.turn}"
          else
            "*** GAME OVER ***"
          end

          format_text_response("""
          === Adventure ===

          > #{action}

          #{response}

          ---
          #{status}
          #{elapsed}ms
          """, host, port) <>
            "i\t\t#{host}\t#{port}\r\n" <>
            "7Take Action\t/adventure/action\t#{host}\t#{port}\r\n" <>
            "1View Inventory\t/adventure/inventory\t#{host}\t#{port}\r\n" <>
            "1Adventure Menu\t/adventure\t#{host}\t#{port}\r\n" <>
            ".\r\n"

        {:error, :no_game} ->
          """
          i=== No Active Game ===\t\t#{host}\t#{port}
          i\t\t#{host}\t#{port}
          iStart a new adventure to play!\t\t#{host}\t#{port}
          i\t\t#{host}\t#{port}
          1Start New Game\t/adventure/new\t#{host}\t#{port}
          .
          """

        {:error, :game_over} ->
          """
          i=== Game Over ===\t\t#{host}\t#{port}
          i\t\t#{host}\t#{port}
          iYour adventure has ended.\t\t#{host}\t#{port}
          i\t\t#{host}\t#{port}
          1Start New Game\t/adventure/new\t#{host}\t#{port}
          .
          """

        {:error, reason} ->
          error_response("Adventure action failed: #{sanitize_error(reason)}")
      end
    end
  end

  defp adventure_look(host, port, ip) do
    session_id = session_id_from_ip(ip)

    case Adventure.look(session_id) do
      {:ok, description} ->
        format_text_response("""
        === Current Scene ===

        #{description}
        """, host, port) <>
          "i\t\t#{host}\t#{port}\r\n" <>
          "7Take Action\t/adventure/action\t#{host}\t#{port}\r\n" <>
          "1Adventure Menu\t/adventure\t#{host}\t#{port}\r\n" <>
          ".\r\n"

      {:error, :not_found} ->
        """
        i=== No Active Game ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/adventure/new\t#{host}\t#{port}
        .
        """

      {:error, :no_context} ->
        """
        i=== No Scene Available ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTake an action to continue the story.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Take Action\t/adventure/action\t#{host}\t#{port}
        .
        """
    end
  end

  defp adventure_inventory(host, port, ip) do
    session_id = session_id_from_ip(ip)

    case Adventure.inventory(session_id) do
      {:ok, items} ->
        items_list = if length(items) > 0 do
          items
          |> Enum.with_index(1)
          |> Enum.map(fn {item, i} -> "i#{i}. #{item}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")
        else
          "iYour inventory is empty.\t\t#{host}\t#{port}"
        end

        """
        i=== Inventory ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{items_list}
        i\t\t#{host}\t#{port}
        7Take Action\t/adventure/action\t#{host}\t#{port}
        1Adventure Menu\t/adventure\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        """
        i=== No Active Game ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/adventure/new\t#{host}\t#{port}
        .
        """
    end
  end

  defp adventure_stats(host, port, ip) do
    session_id = session_id_from_ip(ip)

    case Adventure.stats(session_id) do
      {:ok, stats} ->
        """
        i=== Character Stats ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iHealth:       #{stats.health}/100\t\t#{host}\t#{port}
        iStrength:     #{stats.strength}\t\t#{host}\t#{port}
        iIntelligence: #{stats.intelligence}\t\t#{host}\t#{port}
        iLuck:         #{stats.luck}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Take Action\t/adventure/action\t#{host}\t#{port}
        1Adventure Menu\t/adventure\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        """
        i=== No Active Game ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/adventure/new\t#{host}\t#{port}
        .
        """
    end
  end

  defp adventure_save(host, port, ip) do
    session_id = session_id_from_ip(ip)

    case Adventure.save_game(session_id) do
      {:ok, save_code} ->
        # Split save code into manageable lines
        code_lines = save_code
          |> String.graphemes()
          |> Enum.chunk_every(60)
          |> Enum.map(&Enum.join/1)
          |> Enum.map(&"i#{&1}\t\t#{host}\t#{port}")
          |> Enum.join("\r\n")

        """
        i=== Save Game ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iCopy this save code to restore your game later:\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{code_lines}
        i\t\t#{host}\t#{port}
        1Adventure Menu\t/adventure\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        """
        i=== No Active Game ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo game to save!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/adventure/new\t#{host}\t#{port}
        .
        """
    end
  end

  defp adventure_load_prompt(host, port) do
    """
    i=== Load Game ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your save code to restore your adventure:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter save code:\t/adventure/load\t#{host}\t#{port}
    .
    """
  end

  defp handle_adventure_load(code, host, port, ip) do
    session_id = session_id_from_ip(ip)
    code = String.trim(code)

    case Adventure.load_game(session_id, code) do
      {:ok, state} ->
        """
        i=== Game Loaded ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iWelcome back to your #{state.genre_name} adventure!\t\t#{host}\t#{port}
        iTurn: #{state.turn} | Health: #{state.stats.health}/100\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Continue Adventure\t/adventure/look\t#{host}\t#{port}
        7Take Action\t/adventure/action\t#{host}\t#{port}
        1Adventure Menu\t/adventure\t#{host}\t#{port}
        .
        """

      {:error, :invalid_save} ->
        """
        i=== Invalid Save Code ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iThe save code appears to be corrupted or invalid.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try Again\t/adventure/load\t#{host}\t#{port}
        1Start New Game\t/adventure/new\t#{host}\t#{port}
        .
        """
    end
  end

  # === Feed Aggregator Functions ===

  defp feeds_menu(host, port) do
    feeds = FeedAggregator.list_feeds()

    feed_lines = if length(feeds) > 0 do
      feeds
      |> Enum.map(fn {id, feed} ->
        "1#{feed.name}\t/feeds/#{id}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")
    else
      "iNo feeds configured.\t\t#{host}\t#{port}\r\niAdd feeds in config.exs\t\t#{host}\t#{port}"
    end

    """
    i=== RSS/Atom Feed Aggregator ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSubscribed Feeds:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{feed_lines}
    i\t\t#{host}\t#{port}
    i=== Actions ===\t\t#{host}\t#{port}
    0AI Digest\t/feeds/digest\t#{host}\t#{port}
    0OPML Export\t/feeds/opml\t#{host}\t#{port}
    0Feed Statistics\t/feeds/stats\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp handle_feed_route(rest, host, port) do
    case String.split(rest, "/", parts: 2) do
      [feed_id] ->
        # Show feed entries
        feed_entries(feed_id, host, port)

      [feed_id, "entry", entry_id] ->
        # Show single entry
        feed_entry(feed_id, entry_id, host, port)

      [feed_id, "entry/" <> entry_id] ->
        # Show single entry (alternate path)
        feed_entry(feed_id, entry_id, host, port)

      _ ->
        error_response("Invalid feed path")
    end
  end

  defp feed_entries(feed_id, host, port) do
    case FeedAggregator.get_feed(feed_id) do
      {:ok, feed} ->
        {:ok, entries} = FeedAggregator.get_entries(feed_id, limit: 30)

        entry_lines = if length(entries) > 0 do
          entries
          |> Enum.map(fn entry ->
            date = if entry.published_at, do: Elixir.Calendar.strftime(entry.published_at, "%Y-%m-%d"), else: ""
            title = String.slice(entry.title || "Untitled", 0, 60)
            "0[#{date}] #{title}\t/feeds/#{feed_id}/entry/#{entry.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")
        else
          "iNo entries available.\t\t#{host}\t#{port}"
        end

        """
        i=== #{feed.name} ===\t\t#{host}\t#{port}
        i#{feed.url}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{entry_lines}
        i\t\t#{host}\t#{port}
        1Back to Feeds\t/feeds\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Feed not found")
    end
  end

  defp feed_entry(feed_id, entry_id, host, port) do
    case FeedAggregator.get_entry(feed_id, entry_id) do
      {:ok, entry} ->
        date = if entry.published_at, do: Elixir.Calendar.strftime(entry.published_at, "%Y-%m-%d %H:%M"), else: "Unknown date"
        content = entry.content || entry.summary || "No content available."
        # Truncate very long content
        content = if String.length(content) > 3000, do: String.slice(content, 0, 3000) <> "...", else: content

        format_text_response("""
        === #{entry.title} ===

        Date: #{date}
        Link: #{entry.link}

        #{content}
        """, host, port) <>
          "i\t\t#{host}\t#{port}\r\n" <>
          "1Back to Feed\t/feeds/#{feed_id}\t#{host}\t#{port}\r\n" <>
          "1All Feeds\t/feeds\t#{host}\t#{port}\r\n" <>
          ".\r\n"

      {:error, :not_found} ->
        error_response("Entry not found")
    end
  end

  defp feeds_digest(host, port, socket) do
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      header = format_gopher_lines([
        "=== Feed Digest ===",
        "",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      case FeedAggregator.generate_digest() do
        {:ok, digest} ->
          lines = String.split(digest, "\n", trim: false)
          formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
          ThousandIsland.Socket.send(socket, Enum.join(formatted))

        {:error, reason} ->
          ThousandIsland.Socket.send(socket, "iError: #{sanitize_error(reason)}\t\t#{host}\t#{port}\r\n")
      end

      elapsed = System.monotonic_time(:millisecond) - start_time
      footer = format_gopher_lines([
        "",
        "---",
        "Generated in #{elapsed}ms"
      ], host, port) <>
        "i\t\t#{host}\t#{port}\r\n" <>
        "1Back to Feeds\t/feeds\t#{host}\t#{port}\r\n"

      ThousandIsland.Socket.send(socket, footer <> ".\r\n")
      :streamed
    else
      case FeedAggregator.generate_digest() do
        {:ok, digest} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          format_text_response("""
          === Feed Digest ===

          #{digest}

          ---
          Generated in #{elapsed}ms
          """, host, port) <>
            "i\t\t#{host}\t#{port}\r\n" <>
            "1Back to Feeds\t/feeds\t#{host}\t#{port}\r\n" <>
            ".\r\n"

        {:error, reason} ->
          error_response("Failed to generate digest: #{sanitize_error(reason)}")
      end
    end
  end

  defp feeds_opml(host, port) do
    case FeedAggregator.export_opml() do
      {:ok, opml} ->
        format_text_response(opml, host, port) <>
          "i\t\t#{host}\t#{port}\r\n" <>
          "1Back to Feeds\t/feeds\t#{host}\t#{port}\r\n" <>
          ".\r\n"
    end
  end

  defp feeds_stats(host, port) do
    stats = FeedAggregator.stats()

    feed_lines = stats.feeds
      |> Enum.map(fn feed ->
        last = if feed.last_fetched, do: Elixir.Calendar.strftime(feed.last_fetched, "%Y-%m-%d %H:%M"), else: "Never"
        "i  #{feed.name}: #{feed.entries} entries (last: #{last})\t\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i=== Feed Statistics ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTotal Feeds: #{stats.feed_count}\t\t#{host}\t#{port}
    iTotal Entries: #{stats.entry_count}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i=== Per Feed ===\t\t#{host}\t#{port}
    #{feed_lines}
    i\t\t#{host}\t#{port}
    1Back to Feeds\t/feeds\t#{host}\t#{port}
    .
    """
  end

  # === Weather Functions ===

  defp weather_prompt(host, port) do
    """
    i=== Weather Service ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iGet current weather and forecasts for any location.\t\t#{host}\t#{port}
    iPowered by Open-Meteo (free, no API key needed)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Current Weather\t/weather\t#{host}\t#{port}
    75-Day Forecast\t/weather/forecast\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i  Tokyo\t\t#{host}\t#{port}
    i  New York, US\t\t#{host}\t#{port}
    i  London, UK\t\t#{host}\t#{port}
    i  Paris, France\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp handle_weather(location, host, port, _socket) do
    location = String.trim(location)
    start_time = System.monotonic_time(:millisecond)

    case Weather.get_current(location) do
      {:ok, weather} ->
        elapsed = System.monotonic_time(:millisecond) - start_time

        ascii_lines = weather.ascii
          |> String.split("\n")
          |> Enum.map(&"i#{&1}\t\t#{host}\t#{port}")
          |> Enum.join("\r\n")

        """
        i=== Weather: #{weather.location} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{ascii_lines}
        i\t\t#{host}\t#{port}
        i#{weather.emoji} #{weather.description}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTemperature: #{weather.temperature}#{weather.temperature_unit}\t\t#{host}\t#{port}
        iFeels like:  #{weather.feels_like}#{weather.temperature_unit}\t\t#{host}\t#{port}
        iHumidity:    #{weather.humidity}%\t\t#{host}\t#{port}
        iWind:        #{weather.wind_speed} #{weather.wind_speed_unit} #{weather.wind_direction}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i---\t\t#{host}\t#{port}
        iUpdated in #{elapsed}ms\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Check Another Location\t/weather\t#{host}\t#{port}
        7Get Forecast\t/weather/forecast\t#{host}\t#{port}
        1Back to Home\t/\t#{host}\t#{port}
        .
        """

      {:error, :location_not_found} ->
        error_response("Location not found: #{location}")

      {:error, reason} ->
        error_response("Weather error: #{sanitize_error(reason)}")
    end
  end

  defp handle_weather_forecast(location, host, port, _socket) do
    location = String.trim(location)
    start_time = System.monotonic_time(:millisecond)

    case Weather.get_forecast(location, 5) do
      {:ok, forecast} ->
        elapsed = System.monotonic_time(:millisecond) - start_time

        day_lines = forecast.days
          |> Enum.map(fn day ->
            precip = if day.precipitation_probability, do: " (#{day.precipitation_probability}% rain)", else: ""
            "i#{day.date}: #{day.emoji} #{day.description}\t\t#{host}\t#{port}\r\n" <>
            "i  High: #{day.high}#{forecast.temperature_unit} / Low: #{day.low}#{forecast.temperature_unit}#{precip}\t\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== 5-Day Forecast: #{forecast.location} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{day_lines}
        i\t\t#{host}\t#{port}
        i---\t\t#{host}\t#{port}
        iGenerated in #{elapsed}ms\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Check Another Location\t/weather\t#{host}\t#{port}
        1Back to Home\t/\t#{host}\t#{port}
        .
        """

      {:error, :location_not_found} ->
        error_response("Location not found: #{location}")

      {:error, reason} ->
        error_response("Forecast error: #{sanitize_error(reason)}")
    end
  end

  # === Fortune/Quote Functions ===

  defp fortune_menu(host, port) do
    {:ok, categories} = Fortune.list_categories()

    category_lines = categories
      |> Enum.map(fn cat ->
        "1#{cat.name} (#{cat.count} quotes)\t/fortune/category/#{cat.id}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i=== Fortune & Quotes ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i"The future is not something we enter. The future is\t\t#{host}\t#{port}
    i something we create." - Leonard Sweet\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Quick Actions ---\t\t#{host}\t#{port}
    0Random Quote\t/fortune/random\t#{host}\t#{port}
    0Quote of the Day\t/fortune/today\t#{host}\t#{port}
    0Fortune Cookie\t/fortune/cookie\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Categories ---\t\t#{host}\t#{port}
    #{category_lines}
    i\t\t#{host}\t#{port}
    i--- AI Features ---\t\t#{host}\t#{port}
    7AI Interpretation\t/fortune/interpret\t#{host}\t#{port}
    7Search Quotes\t/fortune/search\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp handle_fortune_random(host, port) do
    case Fortune.random() do
      {:ok, {quote, author, category}} ->
        formatted = Fortune.format_cookie_style({quote, author, category})
        format_text_response("""
        === Random Quote ===

        Category: #{String.capitalize(category)}

        #{formatted}
        """, host, port)

      {:error, reason} ->
        error_response("Fortune error: #{sanitize_error(reason)}")
    end
  end

  defp handle_fortune_of_day(host, port) do
    case Fortune.fortune_of_the_day() do
      {:ok, {quote, author, category}} ->
        formatted = Fortune.format_cookie_style({quote, author, category})
        today = Date.utc_today() |> Date.to_string()
        format_text_response("""
        === Quote of the Day ===
        #{today}

        Category: #{String.capitalize(category)}

        #{formatted}

        Come back tomorrow for a new quote!
        """, host, port)

      {:error, reason} ->
        error_response("Fortune error: #{sanitize_error(reason)}")
    end
  end

  defp handle_fortune_cookie(host, port) do
    case Fortune.fortune_cookie() do
      {:ok, {message, numbers}} ->
        formatted = Fortune.format_fortune_cookie({message, numbers})
        format_text_response("""
        === Fortune Cookie ===

        *crack*

        You open the fortune cookie and find...

        #{formatted}
        """, host, port)

      {:error, reason} ->
        error_response("Fortune error: #{sanitize_error(reason)}")
    end
  end

  defp handle_fortune_category(category, host, port) do
    case Fortune.get_category(category) do
      {:ok, %{name: name, description: desc, quotes: quotes}} ->
        quote_lines = quotes
          |> Enum.take(20)
          |> Enum.map(fn {quote, author} ->
            truncated = if String.length(quote) > 60 do
              String.slice(quote, 0, 57) <> "..."
            else
              quote
            end
            "\"#{truncated}\" - #{author}"
          end)
          |> Enum.join("\n")

        format_text_response("""
        === #{name} ===

        #{desc}

        #{length(quotes)} quotes in this category:

        #{quote_lines}
        """, host, port)

      {:error, :category_not_found} ->
        error_response("Category not found: #{category}")
    end
  end

  defp fortune_interpret_prompt(host, port) do
    """
    iAI Fortune Interpretation\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a quote or select "Random" for AI interpretation:\t\t#{host}\t#{port}
    iTip: You can paste any quote for mystical interpretation.\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_fortune_interpret(input, host, port, socket) do
    input = String.trim(input)

    # If input is "random" or empty, get a random quote first
    {quote, author} = if input == "" or String.downcase(input) == "random" do
      case Fortune.random() do
        {:ok, {q, a, _cat}} -> {q, a}
        _ -> {"The journey is the reward.", "Chinese Proverb"}
      end
    else
      # User provided their own quote
      {input, "Unknown"}
    end

    header = """
    i=== AI Fortune Interpretation ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iQuote: "#{truncate(quote, 50)}"\t\t#{host}\t#{port}
    i- #{author}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iThe Oracle speaks...\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    """

    ThousandIsland.Socket.send(socket, header)

    case Fortune.interpret({quote, author}) do
      {:ok, interpretation} ->
        interpretation
        |> String.split("\n")
        |> Enum.each(fn line ->
          ThousandIsland.Socket.send(socket, "i#{line}\t\t#{host}\t#{port}\r\n")
        end)

      {:error, reason} ->
        ThousandIsland.Socket.send(socket, "iInterpretation failed: #{sanitize_error(reason)}\t\t#{host}\t#{port}\r\n")
    end

    footer = """
    i\t\t#{host}\t#{port}
    7Interpret Another\t/fortune/interpret\t#{host}\t#{port}
    1Back to Fortune\t/fortune\t#{host}\t#{port}
    .
    """
    ThousandIsland.Socket.send(socket, footer)

    :streamed
  end

  defp fortune_search_prompt(host, port) do
    """
    iSearch Quotes\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a keyword to search for quotes:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_fortune_search(keyword, host, port) do
    keyword = String.trim(keyword)

    case Fortune.search(keyword) do
      {:ok, []} ->
        format_text_response("""
        === Search Results for "#{keyword}" ===

        No quotes found matching "#{keyword}".

        Try a different search term.
        """, host, port)

      {:ok, results} ->
        result_lines = results
          |> Enum.take(15)
          |> Enum.map(fn {quote, author, category} ->
            truncated = if String.length(quote) > 70 do
              String.slice(quote, 0, 67) <> "..."
            else
              quote
            end
            "[#{category}] \"#{truncated}\" - #{author}"
          end)
          |> Enum.join("\n\n")

        format_text_response("""
        === Search Results for "#{keyword}" ===

        Found #{length(results)} quote(s):

        #{result_lines}
        """, host, port)

      {:error, reason} ->
        error_response("Search error: #{sanitize_error(reason)}")
    end
  end

  defp truncate(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  # === Calendar Functions ===

  defp calendar_menu(host, port) do
    %{total_events: total, upcoming_events: upcoming} = Calendar.stats()
    today = Date.utc_today()
    {year, month, _day} = {today.year, today.month, today.day}

    """
    i=== Community Calendar ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iShare and discover events!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Upcoming Events\t/calendar/upcoming\t#{host}\t#{port}
    1This Month (#{month_name(month)} #{year})\t/calendar/month/#{year}/#{month}\t#{host}\t#{port}
    7Create Event\t/calendar/create\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Stats ---\t\t#{host}\t#{port}
    iTotal events: #{total}\t\t#{host}\t#{port}
    iUpcoming: #{upcoming}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp calendar_upcoming(host, port) do
    case Calendar.list_upcoming(20) do
      {:ok, []} ->
        format_text_response("""
        === Upcoming Events ===

        No upcoming events scheduled.
        Be the first to create one!
        """, host, port)

      {:ok, events} ->
        event_lines = events
          |> Enum.map(fn e ->
            time_str = if e.time, do: " @ #{e.time}", else: ""
            "1#{e.date}#{time_str}: #{truncate(e.title, 50)}\t/calendar/event/#{e.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Upcoming Events ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{event_lines}
        i\t\t#{host}\t#{port}
        7Create Event\t/calendar/create\t#{host}\t#{port}
        1Back to Calendar\t/calendar\t#{host}\t#{port}
        .
        """
    end
  end

  defp calendar_create_prompt(host, port) do
    """
    i=== Create Event ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: YYYY-MM-DD | Title | Description (optional)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i  2025-01-15 | Monthly Gopher Meetup | Virtual hangout\t\t#{host}\t#{port}
    i  2025-02-01 | New Year's Resolution Check-in\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_calendar_create(input, ip, host, port) do
    parts = String.split(input, "|") |> Enum.map(&String.trim/1)

    case parts do
      [date | rest] when length(rest) >= 1 ->
        [title | desc_parts] = rest
        description = Enum.join(desc_parts, " | ")

        case Calendar.create(ip, title: title, date: date, description: description) do
          {:ok, id} ->
            """
            i=== Event Created! ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iTitle: #{title}\t\t#{host}\t#{port}
            iDate: #{date}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1View Event\t/calendar/event/#{id}\t#{host}\t#{port}
            1Back to Calendar\t/calendar\t#{host}\t#{port}
            .
            """

          {:error, :rate_limited} ->
            error_response("Please wait before creating another event.")

          {:error, :empty_title} ->
            error_response("Please provide an event title.")

          {:error, :invalid_date} ->
            error_response("Invalid date format. Use YYYY-MM-DD.")

          {:error, reason} ->
            error_response("Failed to create event: #{sanitize_error(reason)}")
        end

      _ ->
        error_response("Invalid format. Use: YYYY-MM-DD | Title | Description")
    end
  end

  defp calendar_month(year, month, host, port) do
    case Calendar.list_by_month(year, month) do
      {:ok, events} ->
        # Navigation
        {prev_year, prev_month} = if month == 1, do: {year - 1, 12}, else: {year, month - 1}
        {next_year, next_month} = if month == 12, do: {year + 1, 1}, else: {year, month + 1}

        event_lines = if Enum.empty?(events) do
          "iNo events this month.\t\t#{host}\t#{port}"
        else
          events
          |> Enum.map(fn e ->
            day = String.slice(e.date, 8, 2)
            time_str = if e.time, do: " #{e.time}", else: ""
            "1#{day}#{time_str}: #{truncate(e.title, 45)}\t/calendar/event/#{e.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")
        end

        """
        i=== #{month_name(month)} #{year} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{event_lines}
        i\t\t#{host}\t#{port}
        1<< #{month_name(prev_month)} #{prev_year}\t/calendar/month/#{prev_year}/#{prev_month}\t#{host}\t#{port}
        1>> #{month_name(next_month)} #{next_year}\t/calendar/month/#{next_year}/#{next_month}\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Create Event\t/calendar/create\t#{host}\t#{port}
        1Back to Calendar\t/calendar\t#{host}\t#{port}
        .
        """
    end
  end

  defp calendar_date(date_str, host, port) do
    case Calendar.list_by_date(date_str) do
      {:ok, events} ->
        event_lines = if Enum.empty?(events) do
          "iNo events on this date.\t\t#{host}\t#{port}"
        else
          events
          |> Enum.map(fn e ->
            time_str = if e.time, do: "#{e.time}: ", else: ""
            "1#{time_str}#{truncate(e.title, 50)}\t/calendar/event/#{e.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")
        end

        """
        i=== Events on #{date_str} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{event_lines}
        i\t\t#{host}\t#{port}
        1Back to Calendar\t/calendar\t#{host}\t#{port}
        .
        """
    end
  end

  defp calendar_event(id, host, port) do
    case Calendar.get(id) do
      {:ok, event} ->
        time_line = if event.time, do: "iTime: #{event.time}\t\t#{host}\t#{port}\r\n", else: ""
        location_line = if event.location && event.location != "", do: "iLocation: #{event.location}\t\t#{host}\t#{port}\r\n", else: ""

        desc_lines = if event.description && event.description != "" do
          event.description
          |> String.split("\n")
          |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")
        else
          "iNo description provided.\t\t#{host}\t#{port}"
        end

        """
        i=== #{event.title} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iDate: #{event.date}\t\t#{host}\t#{port}
        #{time_line}#{location_line}i\t\t#{host}\t#{port}
        i--- Description ---\t\t#{host}\t#{port}
        #{desc_lines}
        i\t\t#{host}\t#{port}
        1Back to Upcoming\t/calendar/upcoming\t#{host}\t#{port}
        1Back to Calendar\t/calendar\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Event not found.")
    end
  end

  # === URL Shortener Functions ===

  defp short_menu(host, port) do
    %{total_urls: total, total_clicks: clicks} = UrlShortener.stats()

    """
    i=== URL Shortener ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iCreate short links to share!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Create Short URL\t/short/create\t#{host}\t#{port}
    1Recent Links\t/short/recent\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Stats ---\t\t#{host}\t#{port}
    iTotal URLs: #{total}\t\t#{host}\t#{port}
    iTotal clicks: #{clicks}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp short_create_prompt(host, port) do
    """
    i=== Create Short URL ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter the URL to shorten:\t\t#{host}\t#{port}
    i(Supports http, https, gopher, gemini)\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_short_create(url, ip, host, port) do
    case UrlShortener.create(url, ip) do
      {:ok, code} ->
        """
        i=== Short URL Created! ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iOriginal: #{truncate(url, 50)}\t\t#{host}\t#{port}
        iShort code: #{code}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iShare this link:\t\t#{host}\t#{port}
        i  gopher://#{host}:#{port}/1/short/#{code}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1View Link Info\t/short/info/#{code}\t#{host}\t#{port}
        7Create Another\t/short/create\t#{host}\t#{port}
        1Back to Short URLs\t/short\t#{host}\t#{port}
        .
        """

      {:error, :rate_limited} ->
        error_response("Please wait before creating another short URL.")

      {:error, :empty_url} ->
        error_response("Please provide a URL.")

      {:error, :url_too_long} ->
        error_response("URL is too long (max 2000 characters).")

      {:error, :invalid_url} ->
        error_response("Invalid URL. Must start with http://, https://, gopher://, or gemini://")

      {:error, reason} ->
        error_response("Failed to create short URL: #{sanitize_error(reason)}")
    end
  end

  defp short_recent(host, port) do
    case UrlShortener.list_recent(20) do
      {:ok, []} ->
        format_text_response("""
        === Recent Short URLs ===

        No short URLs created yet.
        Be the first to create one!
        """, host, port)

      {:ok, urls} ->
        url_lines = urls
          |> Enum.map(fn u ->
            clicks = if u.clicks == 1, do: "1 click", else: "#{u.clicks} clicks"
            "1#{u.code}: #{truncate(u.url, 40)} (#{clicks})\t/short/info/#{u.code}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Recent Short URLs ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{url_lines}
        i\t\t#{host}\t#{port}
        7Create Short URL\t/short/create\t#{host}\t#{port}
        1Back to Short URLs\t/short\t#{host}\t#{port}
        .
        """
    end
  end

  defp short_info(code, host, port) do
    case UrlShortener.info(code) do
      {:ok, info} ->
        created = format_date(info.created_at)
        clicks = if info.clicks == 1, do: "1 click", else: "#{info.clicks} clicks"

        """
        i=== Short URL Info ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iCode: #{info.code}\t\t#{host}\t#{port}
        iOriginal URL:\t\t#{host}\t#{port}
        i  #{info.url}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iCreated: #{created}\t\t#{host}\t#{port}
        iClicks: #{clicks}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Go to URL\t/short/#{code}\t#{host}\t#{port}
        1Back to Recent\t/short/recent\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Short URL not found.")
    end
  end

  defp short_redirect(code, host, port) do
    case UrlShortener.get(code) do
      {:ok, url} ->
        cond do
          String.starts_with?(url, "gopher://") ->
            # Parse gopher URL and redirect
            uri = URI.parse(url)
            target_host = uri.host || host
            target_port = uri.port || 70
            path = uri.path || ""

            """
            i=== Redirecting ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iYou are being redirected to:\t\t#{host}\t#{port}
            i#{url}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Click here to continue\t#{path}\t#{target_host}\t#{target_port}
            .
            """

          String.starts_with?(url, "gemini://") or String.starts_with?(url, "http") ->
            # External URL - show as HTML link type
            """
            i=== External Link ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iThis link goes to an external site:\t\t#{host}\t#{port}
            i#{url}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            hClick here to open\tURL:#{url}\t#{host}\t#{port}
            .
            """

          true ->
            error_response("Unknown URL type.")
        end

      {:error, :not_found} ->
        error_response("Short URL not found: #{code}")
    end
  end

  # === Quick Utilities Functions ===

  defp utils_menu(host, port) do
    """
    i=== Quick Utilities ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iHandy tools for the Gopher community!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Random & Games ---\t\t#{host}\t#{port}
    7Roll Dice\t/utils/dice\t#{host}\t#{port}
    7Magic 8-Ball\t/utils/8ball\t#{host}\t#{port}
    0Flip a Coin\t/utils/coin\t#{host}\t#{port}
    7Random Number\t/utils/random\t#{host}\t#{port}
    7Pick Random Item\t/utils/pick\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Generators ---\t\t#{host}\t#{port}
    0Generate UUID\t/utils/uuid\t#{host}\t#{port}
    0Generate Password (16)\t/utils/password\t#{host}\t#{port}
    0Generate Password (32)\t/utils/password/32\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Encoding & Hashing ---\t\t#{host}\t#{port}
    7Calculate Hash\t/utils/hash\t#{host}\t#{port}
    7Base64 Encode\t/utils/base64/encode\t#{host}\t#{port}
    7Base64 Decode\t/utils/base64/decode\t#{host}\t#{port}
    7ROT13 Cipher\t/utils/rot13\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Time & Text ---\t\t#{host}\t#{port}
    0Current Timestamp\t/utils/now\t#{host}\t#{port}
    7Convert Timestamp\t/utils/timestamp\t#{host}\t#{port}
    7Count Text\t/utils/count\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp utils_dice_prompt(host, port) do
    """
    i=== Roll Dice ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter dice notation (e.g., 2d6, 1d20+5, 3d10-2):\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_dice(spec, host, port) do
    case Utilities.roll_dice(spec) do
      {:ok, result} ->
        rolls_str = result.rolls |> Enum.join(", ")
        modifier_str = cond do
          result.modifier > 0 -> " + #{result.modifier}"
          result.modifier < 0 -> " - #{abs(result.modifier)}"
          true -> ""
        end

        """
        i=== Dice Roll: #{result.count}d#{result.sides}#{modifier_str} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iRolls: [#{rolls_str}]\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i  Total: #{result.total}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Roll Again\t/utils/dice\t#{host}\t#{port}
        1Back to Utilities\t/utils\t#{host}\t#{port}
        .
        """

      {:error, :invalid_spec} ->
        error_response("Invalid dice spec. Use format like 2d6 (1-100 dice, 1-1000 sides).")

      {:error, :parse_error} ->
        error_response("Could not parse dice spec. Use format like 2d6, 1d20+5, 3d10-2.")
    end
  end

  defp utils_8ball_prompt(host, port) do
    """
    i=== Magic 8-Ball ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAsk your question:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_8ball(question, host, port) do
    answer = Utilities.magic_8ball()

    """
    i=== Magic 8-Ball ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iYou asked: #{truncate(question, 50)}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i   *shake shake shake*\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i  The 8-Ball says:\t\t#{host}\t#{port}
    i  "#{answer}"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Ask Another Question\t/utils/8ball\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  defp handle_coin_flip(host, port) do
    result = Utilities.coin_flip()
    result_str = if result == :heads, do: "HEADS", else: "TAILS"
    emoji = if result == :heads, do: "(o)", else: "(x)"

    """
    i=== Coin Flip ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i   *flip*\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i    #{emoji}\t\t#{host}\t#{port}
    i  #{result_str}!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    0Flip Again\t/utils/coin\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  defp utils_random_prompt(host, port) do
    """
    i=== Random Number ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter range as "min max" (e.g., 1 100):\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_random(range, host, port) do
    case String.split(range, ~r/[\s,\-]+/, trim: true) do
      [min_str, max_str] ->
        with {min, ""} <- Integer.parse(min_str),
             {max, ""} <- Integer.parse(max_str),
             {:ok, number} <- Utilities.random_number(min, max) do
          """
          i=== Random Number ===\t\t#{host}\t#{port}
          i\t\t#{host}\t#{port}
          iRange: #{min} to #{max}\t\t#{host}\t#{port}
          i\t\t#{host}\t#{port}
          i  Result: #{number}\t\t#{host}\t#{port}
          i\t\t#{host}\t#{port}
          7Generate Another\t/utils/random\t#{host}\t#{port}
          1Back to Utilities\t/utils\t#{host}\t#{port}
          .
          """
        else
          _ -> error_response("Invalid range. Use format: min max (e.g., 1 100)")
        end

      [max_str] ->
        case Integer.parse(max_str) do
          {max, ""} when max > 0 ->
            {:ok, number} = Utilities.random_number(1, max)
            """
            i=== Random Number ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iRange: 1 to #{max}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            i  Result: #{number}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            7Generate Another\t/utils/random\t#{host}\t#{port}
            1Back to Utilities\t/utils\t#{host}\t#{port}
            .
            """

          _ -> error_response("Invalid number. Enter a positive integer.")
        end

      _ ->
        error_response("Invalid format. Use: min max (e.g., 1 100) or just max (e.g., 100)")
    end
  end

  defp handle_uuid(host, port) do
    uuid = Utilities.generate_uuid()

    """
    i=== UUID Generator ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iGenerated UUID v4:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i  #{uuid}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    0Generate Another\t/utils/uuid\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  defp utils_hash_prompt(host, port) do
    """
    i=== Hash Calculator ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter text to hash:\t\t#{host}\t#{port}
    i(Calculates MD5, SHA1, SHA256, SHA512)\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_hash(input, host, port) do
    md5 = Utilities.calculate_hash(input, :md5)
    sha1 = Utilities.calculate_hash(input, :sha1)
    sha256 = Utilities.calculate_hash(input, :sha256)
    sha512 = Utilities.calculate_hash(input, :sha512)

    """
    i=== Hash Results ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iInput: #{truncate(input, 40)}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iMD5:\t\t#{host}\t#{port}
    i  #{md5}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSHA1:\t\t#{host}\t#{port}
    i  #{sha1}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSHA256:\t\t#{host}\t#{port}
    i  #{sha256}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSHA512:\t\t#{host}\t#{port}
    i  #{String.slice(sha512, 0, 64)}\t\t#{host}\t#{port}
    i  #{String.slice(sha512, 64, 64)}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Hash Another\t/utils/hash\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  defp utils_base64_encode_prompt(host, port) do
    """
    i=== Base64 Encode ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter text to encode:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_base64_encode(input, host, port) do
    encoded = Utilities.base64_encode(input)

    """
    i=== Base64 Encoded ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iInput: #{truncate(input, 40)}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEncoded:\t\t#{host}\t#{port}
    i  #{encoded}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Encode Another\t/utils/base64/encode\t#{host}\t#{port}
    7Decode Base64\t/utils/base64/decode\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  defp utils_base64_decode_prompt(host, port) do
    """
    i=== Base64 Decode ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter Base64 string to decode:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_base64_decode(input, host, port) do
    case Utilities.base64_decode(input) do
      {:ok, decoded} ->
        """
        i=== Base64 Decoded ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iInput: #{truncate(input, 40)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iDecoded:\t\t#{host}\t#{port}
        i  #{truncate(decoded, 60)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Decode Another\t/utils/base64/decode\t#{host}\t#{port}
        7Encode Base64\t/utils/base64/encode\t#{host}\t#{port}
        1Back to Utilities\t/utils\t#{host}\t#{port}
        .
        """

      {:error, :invalid_base64} ->
        error_response("Invalid Base64 string. Please check your input.")
    end
  end

  defp utils_rot13_prompt(host, port) do
    """
    i=== ROT13 Cipher ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter text to encode/decode:\t\t#{host}\t#{port}
    i(ROT13 is its own inverse!)\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_rot13(input, host, port) do
    result = Utilities.rot13(input)

    """
    i=== ROT13 Result ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iInput:  #{truncate(input, 40)}\t\t#{host}\t#{port}
    iOutput: #{truncate(result, 40)}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Convert Another\t/utils/rot13\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  defp handle_password(length, host, port) do
    password = Utilities.generate_password(length)

    """
    i=== Password Generator ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iGenerated Password (#{length} chars):\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i  #{password}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i(Contains: a-z, A-Z, 0-9, symbols)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    0Generate Another (16)\t/utils/password\t#{host}\t#{port}
    0Generate Another (32)\t/utils/password/32\t#{host}\t#{port}
    0Generate Another (64)\t/utils/password/64\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  defp utils_timestamp_prompt(host, port) do
    """
    i=== Timestamp Converter ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter Unix timestamp to convert:\t\t#{host}\t#{port}
    i(e.g., 1735689600)\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_timestamp(ts_str, host, port) do
    case Integer.parse(String.trim(ts_str)) do
      {ts, ""} ->
        case Utilities.timestamp_to_date(ts) do
          {:ok, date_str} ->
            """
            i=== Timestamp Converted ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iUnix timestamp: #{ts}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iDate/Time (UTC):\t\t#{host}\t#{port}
            i  #{date_str}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            7Convert Another\t/utils/timestamp\t#{host}\t#{port}
            0Current Timestamp\t/utils/now\t#{host}\t#{port}
            1Back to Utilities\t/utils\t#{host}\t#{port}
            .
            """

          {:error, _} ->
            error_response("Invalid timestamp. Must be a valid Unix timestamp.")
        end

      _ ->
        error_response("Invalid input. Please enter a numeric timestamp.")
    end
  end

  defp handle_now(host, port) do
    ts = Utilities.current_timestamp()
    {:ok, date_str} = Utilities.timestamp_to_date(ts)

    """
    i=== Current Time ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iUnix timestamp: #{ts}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iDate/Time (UTC):\t\t#{host}\t#{port}
    i  #{date_str}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    0Refresh\t/utils/now\t#{host}\t#{port}
    7Convert Timestamp\t/utils/timestamp\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  defp utils_pick_prompt(host, port) do
    """
    i=== Random Pick ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter comma-separated items:\t\t#{host}\t#{port}
    i(e.g., red, blue, green)\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_pick(items_str, host, port) do
    items = items_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Utilities.random_pick(items) do
      {:ok, winner} ->
        """
        i=== Random Pick ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iFrom #{length(items)} items:\t\t#{host}\t#{port}
        i  [#{Enum.join(items, ", ")}]\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i  Winner: #{winner}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Pick Again\t/utils/pick\t#{host}\t#{port}
        1Back to Utilities\t/utils\t#{host}\t#{port}
        .
        """

      {:error, :empty_list} ->
        error_response("Please provide at least one item to pick from.")
    end
  end

  defp utils_count_prompt(host, port) do
    """
    i=== Text Counter ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter text to count:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_count(text, host, port) do
    counts = Utilities.count_text(text)

    """
    i=== Text Statistics ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iText: #{truncate(text, 40)}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iCharacters: #{counts.characters}\t\t#{host}\t#{port}
    iWords: #{counts.words}\t\t#{host}\t#{port}
    iLines: #{counts.lines}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Count Another\t/utils/count\t#{host}\t#{port}
    1Back to Utilities\t/utils\t#{host}\t#{port}
    .
    """
  end

  # === Sitemap Functions ===

  defp sitemap_index(host, port) do
    categories = Sitemap.all_selectors()
    stats = Sitemap.stats()

    category_lines = categories
      |> Enum.map(fn cat ->
        "1#{cat.category} (#{length(cat.items)} items)\t/sitemap/category/#{String.downcase(cat.category) |> String.replace(" ", "-")}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i=== Full Sitemap ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iComplete index of all server endpoints.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Statistics ---\t\t#{host}\t#{port}
    iTotal Endpoints: #{stats.total_selectors}\t\t#{host}\t#{port}
    iMenus: #{stats.menus} | Documents: #{stats.documents} | Queries: #{stats.search_queries}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Categories ---\t\t#{host}\t#{port}
    #{category_lines}
    i\t\t#{host}\t#{port}
    i--- Actions ---\t\t#{host}\t#{port}
    7Search Sitemap\t/sitemap/search\t#{host}\t#{port}
    0Plain Text Version\t/sitemap/text\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp sitemap_category(category_slug, host, port) do
    # Convert slug back to category name
    category_name = category_slug
      |> String.replace("-", " ")
      |> String.split()
      |> Enum.map(&String.capitalize/1)
      |> Enum.join(" ")

    case Sitemap.by_category(category_name) do
      {:ok, cat} ->
        item_lines = cat.items
          |> Enum.map(fn item ->
            type_char = case item.type do
              0 -> "0"
              1 -> "1"
              7 -> "7"
              _ -> "i"
            end
            "#{type_char}#{item.selector} - #{item.description}\t#{item.selector}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== #{cat.category} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{length(cat.items)} endpoints in this category.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{item_lines}
        i\t\t#{host}\t#{port}
        1Back to Sitemap\t/sitemap\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Category not found: #{category_name}")
    end
  end

  defp sitemap_search_prompt(host, port) do
    """
    i=== Search Sitemap ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a search term to find endpoints:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_sitemap_search(query, host, port) do
    results = Sitemap.search(query)

    if Enum.empty?(results) do
      """
      i=== Search Results ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      iNo results found for: #{truncate(query, 40)}\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      7Search Again\t/sitemap/search\t#{host}\t#{port}
      1Back to Sitemap\t/sitemap\t#{host}\t#{port}
      .
      """
    else
      result_lines = results
        |> Enum.take(20)
        |> Enum.map(fn item ->
          type_char = case item.type do
            0 -> "0"
            1 -> "1"
            7 -> "7"
            _ -> "i"
          end
          "#{type_char}#{item.selector} - #{item.description}\t#{item.selector}\t#{host}\t#{port}"
        end)
        |> Enum.join("\r\n")

      """
      i=== Search Results: "#{truncate(query, 30)}" ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      iFound #{length(results)} matches.\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      #{result_lines}
      i\t\t#{host}\t#{port}
      7Search Again\t/sitemap/search\t#{host}\t#{port}
      1Back to Sitemap\t/sitemap\t#{host}\t#{port}
      .
      """
    end
  end

  defp sitemap_text(host, port) do
    text = Sitemap.to_text()

    format_text_response("""
    PureGopherAI Server - Full Sitemap
    ===================================

    #{text}

    ---
    Generated: #{DateTime.utc_now() |> DateTime.to_string()}
    """, host, port)
  end

  # === Mailbox Functions ===

  defp mail_menu(host, port) do
    stats = Mailbox.stats()

    """
    i=== Mailbox ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPrivate messaging for registered users.\t\t#{host}\t#{port}
    i(You need a user profile to use mailbox)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Stats ---\t\t#{host}\t#{port}
    iTotal messages: #{stats.total_messages}\t\t#{host}\t#{port}
    iUnread messages: #{stats.total_unread}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Access Mailbox ---\t\t#{host}\t#{port}
    7Enter your username\t/mail/login\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Create a Profile\t/users/create\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp mail_login_prompt(host, port) do
    """
    i=== Mailbox Login ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter: username:passphrase\t\t#{host}\t#{port}
    i(e.g., myname:mysecretpassword)\t\t#{host}\t#{port}
    .
    """
  end

  defp mail_inbox(input, host, port) do
    case String.split(String.trim(input), ":", parts: 2) do
      [username, passphrase] when byte_size(passphrase) > 0 ->
        case Mailbox.get_inbox(username, passphrase, limit: 20) do
          {:ok, []} ->
            case Mailbox.unread_count(username, passphrase) do
              {:ok, _} ->
                """
                i=== Inbox: #{username} ===\t\t#{host}\t#{port}
                i\t\t#{host}\t#{port}
                iNo messages yet.\t\t#{host}\t#{port}
                i\t\t#{host}\t#{port}
                7Compose New Message\t/mail/compose/#{username}\t#{host}\t#{port}
                1Back to Mailbox\t/mail\t#{host}\t#{port}
                .
                """
              {:error, _} ->
                error_response("Invalid credentials.")
            end

          {:ok, messages} ->
            message_lines = messages
              |> Enum.map(fn msg ->
                status = if msg.read, do: "   ", else: "[*]"
                date = format_date(msg.created_at)
                "0#{status} #{truncate(msg.subject, 30)} - from #{msg.from} (#{date})\t/mail/read/#{username}/#{msg.id}\t#{host}\t#{port}"
              end)
              |> Enum.join("\r\n")

            """
            i=== Inbox: #{username} ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            i[*] = unread\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            #{message_lines}
            i\t\t#{host}\t#{port}
            7Compose New Message\t/mail/compose/#{username}\t#{host}\t#{port}
            1Back to Mailbox\t/mail\t#{host}\t#{port}
            .
            """

          {:error, :invalid_credentials} ->
            error_response("Invalid credentials.")

          {:error, reason} ->
            error_response("Failed to load inbox: #{sanitize_error(reason)}")
        end

      _ ->
        error_response("Invalid format. Use: username:passphrase")
    end
  end

  defp mail_inbox_prompt(username, host, port) do
    """
    i=== Access Inbox: #{username} ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPlease log in via the main mailbox menu.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Login to Mailbox\t/mail/login\t#{host}\t#{port}
    1Back to Mailbox\t/mail\t#{host}\t#{port}
    .
    """
  end

  defp mail_sent_prompt(username, host, port) do
    """
    i=== Sent Messages: #{username} ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPlease log in via the main mailbox menu.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Login to Mailbox\t/mail/login\t#{host}\t#{port}
    1Back to Mailbox\t/mail\t#{host}\t#{port}
    .
    """
  end


  defp mail_read(_username, _message_id, host, port) do
    # Reading messages now requires passphrase authentication
    # Please log in via the main mailbox menu
    """
    i=== Read Message ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPlease log in to access your messages.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Login to Mailbox\t/mail/login\t#{host}\t#{port}
    1Back to Mailbox\t/mail\t#{host}\t#{port}
    .
    """
  end

  defp mail_compose_prompt(username, host, port) do
    """
    i=== Compose Message ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFrom: #{username}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter recipient username:\t\t#{host}\t#{port}
    .
    """
  end

  defp mail_compose_to_prompt(from_user, to_user, host, port) do
    """
    i=== Compose Message ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFrom: #{from_user}\t\t#{host}\t#{port}
    iTo: #{to_user}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your message in format:\t\t#{host}\t#{port}
    iSubject | Message body\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExample: Hello! | Nice to meet you!\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_mail_send(from_user, to_user, content, ip, host, port) do
    case String.split(content, "|", parts: 2) do
      [subject, body] ->
        subject = String.trim(subject)
        body = String.trim(body)

        case Mailbox.send_message(from_user, to_user, subject, body, ip) do
          {:ok, _message_id} ->
            """
            i=== Message Sent! ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iYour message to #{to_user} has been sent.\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iSubject: #{truncate(subject, 40)}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            7Send Another Message\t/mail/compose/#{from_user}\t#{host}\t#{port}
            1Back to Inbox\t/mail/inbox/#{from_user}\t#{host}\t#{port}
            .
            """

          {:error, :rate_limited} ->
            error_response("Please wait before sending another message.")

          {:error, :recipient_not_found} ->
            error_response("User '#{to_user}' not found. They must have a profile first.")

          {:error, :recipient_inbox_full} ->
            error_response("#{to_user}'s inbox is full.")

          {:error, :cannot_message_self} ->
            error_response("You cannot send a message to yourself.")

          {:error, :empty_subject} ->
            error_response("Subject cannot be empty.")

          {:error, :empty_message} ->
            error_response("Message body cannot be empty.")

          {:error, :subject_too_long} ->
            error_response("Subject is too long (max 100 characters).")

          {:error, :message_too_long} ->
            error_response("Message is too long (max 2000 characters).")

          {:error, reason} ->
            error_response("Failed to send message: #{sanitize_error(reason)}")
        end

      [_only_subject] ->
        error_response("Invalid format. Use: Subject | Message body")
    end
  end

  defp handle_mail_delete(_username, _message_id, host, port) do
    # Deleting messages now requires passphrase authentication
    """
    i=== Delete Message ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPlease log in to manage your messages.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Login to Mailbox\t/mail/login\t#{host}\t#{port}
    1Back to Mailbox\t/mail\t#{host}\t#{port}
    .
    """
  end

  # === Trivia Functions ===

  defp trivia_menu(session_id, host, port) do
    stats = Trivia.stats()
    score = Trivia.get_score(session_id)
    categories = Trivia.categories()

    category_lines = categories
      |> Enum.map(fn cat ->
        "1Play #{String.capitalize(cat)}\t/trivia/play/#{cat}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    score_line = if score.total > 0 do
      pct = round(score.correct / score.total * 100)
      "iCurrent Score: #{score.correct}/#{score.total} (#{pct}%)\t\t#{host}\t#{port}"
    else
      "iNo score yet - start playing!\t\t#{host}\t#{port}"
    end

    """
    i=== Trivia Quiz ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTest your knowledge!\t\t#{host}\t#{port}
    i#{stats.total_questions} questions in #{stats.total_categories} categories.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{score_line}
    i\t\t#{host}\t#{port}
    i--- Play by Category ---\t\t#{host}\t#{port}
    1Play Random (All Categories)\t/trivia/play\t#{host}\t#{port}
    #{category_lines}
    i\t\t#{host}\t#{port}
    i--- Your Stats ---\t\t#{host}\t#{port}
    0View Your Score\t/trivia/score\t#{host}\t#{port}
    7Save Score to Leaderboard\t/trivia/save\t#{host}\t#{port}
    0Reset Score\t/trivia/reset\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Leaderboard\t/trivia/leaderboard\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp trivia_play(session_id, category, host, port) do
    case Trivia.get_question(category) do
      {:ok, question} ->
        score = Trivia.get_score(session_id)

        option_lines = question.options
          |> Enum.with_index(1)
          |> Enum.map(fn {opt, idx} ->
            "1#{idx}. #{opt}\t/trivia/answer/#{question.id}/#{idx}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        score_line = if score.total > 0 do
          "iScore: #{score.correct}/#{score.total}\t\t#{host}\t#{port}"
        else
          "iScore: 0/0\t\t#{host}\t#{port}"
        end

        """
        i=== Trivia: #{String.capitalize(question.category)} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{score_line}
        i\t\t#{host}\t#{port}
        iQuestion:\t\t#{host}\t#{port}
        i#{question.question}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i--- Select Your Answer ---\t\t#{host}\t#{port}
        #{option_lines}
        i\t\t#{host}\t#{port}
        1Back to Trivia Menu\t/trivia\t#{host}\t#{port}
        .
        """

      {:error, :no_questions} ->
        error_response("No questions available for this category.")
    end
  end

  defp trivia_answer_prompt(_question_id, host, port) do
    """
    i=== Answer Question ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your answer (1-4):\t\t#{host}\t#{port}
    .
    """
  end

  defp trivia_answer(session_id, question_id, answer, host, port) do
    case Trivia.check_answer(session_id, question_id, answer) do
      {:ok, result} ->
        score = Trivia.get_score(session_id)
        pct = if score.total > 0, do: round(score.correct / score.total * 100), else: 0

        result_text = if result.correct do
          "iCorrect!\t\t#{host}\t#{port}"
        else
          "iWrong! The answer was: #{result.correct_answer}\t\t#{host}\t#{port}"
        end

        """
        i=== Answer Result ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{result_text}
        i\t\t#{host}\t#{port}
        iYour Score: #{score.correct}/#{score.total} (#{pct}%)\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Next Question\t/trivia/play\t#{host}\t#{port}
        7Save Score to Leaderboard\t/trivia/save\t#{host}\t#{port}
        1Back to Trivia Menu\t/trivia\t#{host}\t#{port}
        .
        """

      {:error, :question_not_found} ->
        error_response("Question expired or invalid. Please try a new question.")
    end
  end

  defp trivia_score(session_id, host, port) do
    score = Trivia.get_score(session_id)

    if score.total == 0 do
      """
      i=== Your Trivia Score ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      iNo score yet!\t\t#{host}\t#{port}
      iStart playing to build your score.\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1Play Trivia\t/trivia/play\t#{host}\t#{port}
      1Back to Trivia Menu\t/trivia\t#{host}\t#{port}
      .
      """
    else
      pct = round(score.correct / score.total * 100)

      grade = cond do
        pct >= 90 -> "A - Excellent!"
        pct >= 80 -> "B - Great!"
        pct >= 70 -> "C - Good"
        pct >= 60 -> "D - Keep trying"
        true -> "F - Study more!"
      end

      """
      i=== Your Trivia Score ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      iCorrect: #{score.correct}\t\t#{host}\t#{port}
      iTotal Questions: #{score.total}\t\t#{host}\t#{port}
      iAccuracy: #{pct}%\t\t#{host}\t#{port}
      iGrade: #{grade}\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1Continue Playing\t/trivia/play\t#{host}\t#{port}
      7Save to Leaderboard\t/trivia/save\t#{host}\t#{port}
      0Reset Score\t/trivia/reset\t#{host}\t#{port}
      1Back to Trivia Menu\t/trivia\t#{host}\t#{port}
      .
      """
    end
  end

  defp trivia_reset(session_id, host, port) do
    Trivia.reset_score(session_id)

    """
    i=== Score Reset ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iYour score has been reset to 0/0.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Play Again\t/trivia/play\t#{host}\t#{port}
    1Back to Trivia Menu\t/trivia\t#{host}\t#{port}
    .
    """
  end

  defp trivia_leaderboard(host, port) do
    case Trivia.leaderboard(10) do
      {:ok, []} ->
        """
        i=== Trivia Leaderboard ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo scores saved yet!\t\t#{host}\t#{port}
        iBe the first to save your score.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Play Trivia\t/trivia/play\t#{host}\t#{port}
        1Back to Trivia Menu\t/trivia\t#{host}\t#{port}
        .
        """

      {:ok, scores} ->
        score_lines = scores
          |> Enum.with_index(1)
          |> Enum.map(fn {s, rank} ->
            "i#{rank}. #{s.nickname} - #{s.correct}/#{s.total} (#{s.percentage}%)\t\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Trivia Leaderboard ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i--- Top 10 Scores ---\t\t#{host}\t#{port}
        #{score_lines}
        i\t\t#{host}\t#{port}
        1Play Trivia\t/trivia/play\t#{host}\t#{port}
        1Back to Trivia Menu\t/trivia\t#{host}\t#{port}
        .
        """
    end
  end

  defp trivia_save_prompt(host, port) do
    """
    i=== Save Your Score ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your nickname to save to leaderboard:\t\t#{host}\t#{port}
    .
    """
  end

  defp trivia_save(session_id, nickname, host, port) do
    case Trivia.save_score(session_id, nickname) do
      {:ok, entry} ->
        """
        i=== Score Saved! ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNickname: #{entry.nickname}\t\t#{host}\t#{port}
        iScore: #{entry.correct}/#{entry.total} (#{entry.percentage}%)\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iYour score has been added to the leaderboard!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1View Leaderboard\t/trivia/leaderboard\t#{host}\t#{port}
        1Play Again\t/trivia/play\t#{host}\t#{port}
        1Back to Trivia Menu\t/trivia\t#{host}\t#{port}
        .
        """

      {:error, :no_score} ->
        error_response("No score to save. Play some trivia first!")

      {:error, :invalid_nickname} ->
        error_response("Invalid nickname. Use letters, numbers, and spaces only.")
    end
  end

  # === Bookmarks Functions ===

  defp bookmarks_menu(host, port) do
    stats = Bookmarks.stats()

    """
    i=== Bookmarks / Favorites ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSave your favorite selectors for quick access.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTotal users: #{stats.total_users}\t\t#{host}\t#{port}
    iTotal bookmarks: #{stats.total_bookmarks}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Access Your Bookmarks ---\t\t#{host}\t#{port}
    7Enter your username\t/bookmarks/login\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTip: Use a registered username from /users\t\t#{host}\t#{port}
    ito keep your bookmarks persistent.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp bookmarks_login_prompt(host, port) do
    """
    i=== Bookmarks Login ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter username:passphrase to access bookmarks:\t\t#{host}\t#{port}
    i(e.g., myname:mysecretpassword123)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTip: Register at /users first if you don't have an account.\t\t#{host}\t#{port}
    .
    """
  end

  defp bookmarks_login_redirect(host, port) do
    """
    i=== Authentication Required ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPlease log in to access your bookmarks.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Log In\t/bookmarks/login\t#{host}\t#{port}
    1Back to Bookmarks Menu\t/bookmarks\t#{host}\t#{port}
    .
    """
  end

  defp handle_bookmarks_login(input, host, port, ip) do
    input = String.trim(input)

    case String.split(input, ":", parts: 2) do
      [username, passphrase] when username != "" and passphrase != "" ->
        username = String.trim(username)
        passphrase = String.trim(passphrase)

        # Verify credentials
        case UserProfiles.authenticate(username, passphrase) do
          {:ok, _profile} ->
            # URL-encode the passphrase to handle special characters
            encoded_pass = URI.encode(passphrase, &URI.char_unreserved?/1)
            bookmarks_user(username, encoded_pass, nil, host, port, ip)

          {:error, :user_not_found} ->
            error_response("User not found. Register at /users first.")

          {:error, :invalid_credentials} ->
            error_response("Invalid passphrase.")

          {:error, :rate_limited} ->
            error_response("Too many failed attempts. Try again later.")

          {:error, _} ->
            error_response("Authentication failed.")
        end

      _ ->
        error_response("Invalid format. Use: username:passphrase")
    end
  end

  defp bookmarks_user(username, passphrase, folder, host, port, _ip) do
    username = String.trim(username)
    # Decode the passphrase from URL encoding
    passphrase = URI.decode(passphrase)

    case Bookmarks.list(username, passphrase, folder) do
      {:ok, bookmarks} ->
        case Bookmarks.folders(username, passphrase) do
          {:ok, folders} ->
            case Bookmarks.count(username, passphrase) do
              {:ok, count} ->
                current_folder = folder || "default"
                # Re-encode for URLs
                encoded_pass = URI.encode(passphrase, &URI.char_unreserved?/1)

                folder_lines = folders
                  |> Enum.map(fn f ->
                    indicator = if f == current_folder, do: "[*] ", else: "    "
                    "1#{indicator}#{f}\t/bookmarks/user/#{username}/#{encoded_pass}/#{f}\t#{host}\t#{port}"
                  end)
                  |> Enum.join("\r\n")

                bookmark_lines = if Enum.empty?(bookmarks) do
                  "iNo bookmarks in this folder yet.\t\t#{host}\t#{port}"
                else
                  bookmarks
                  |> Enum.map(fn b ->
                    # Determine the type from the selector
                    type = cond do
                      String.starts_with?(b.selector, "/ask") -> "7"
                      String.starts_with?(b.selector, "/chat") -> "7"
                      String.starts_with?(b.selector, "/search") -> "7"
                      String.ends_with?(b.selector, "/") -> "1"
                      true -> "1"
                    end
                    "#{type}#{b.title}\t#{b.selector}\t#{host}\t#{port}\r\n" <>
                    "i    [#{b.folder}] Added: #{String.slice(b.created_at, 0, 10)}\t\t#{host}\t#{port}\r\n" <>
                    "1    [Remove]\t/bookmarks/remove/#{username}/#{encoded_pass}/#{b.id}\t#{host}\t#{port}"
                  end)
                  |> Enum.join("\r\n")
                end

                """
                i=== #{username}'s Bookmarks ===\t\t#{host}\t#{port}
                i\t\t#{host}\t#{port}
                iTotal bookmarks: #{count}/100\t\t#{host}\t#{port}
                iCurrent folder: #{current_folder}\t\t#{host}\t#{port}
                i\t\t#{host}\t#{port}
                i--- Folders ---\t\t#{host}\t#{port}
                #{folder_lines}
                i\t\t#{host}\t#{port}
                i--- Bookmarks ---\t\t#{host}\t#{port}
                #{bookmark_lines}
                i\t\t#{host}\t#{port}
                i--- Actions ---\t\t#{host}\t#{port}
                7Add Bookmark\t/bookmarks/add/#{username}/#{encoded_pass}\t#{host}\t#{port}
                7New Folder\t/bookmarks/newfolder/#{username}/#{encoded_pass}\t#{host}\t#{port}
                0Export Bookmarks\t/bookmarks/export/#{username}/#{encoded_pass}\t#{host}\t#{port}
                i\t\t#{host}\t#{port}
                1Back to Menu\t/bookmarks\t#{host}\t#{port}
                .
                """

              {:error, _} ->
                error_response("Authentication failed.")
            end

          {:error, _} ->
            error_response("Authentication failed.")
        end

      {:error, :invalid_credentials} ->
        error_response("Invalid passphrase.")

      {:error, :user_not_found} ->
        error_response("User not found. Register at /users first.")

      {:error, _} ->
        error_response("Could not retrieve bookmarks.")
    end
  end

  defp bookmarks_add_prompt(_username, _passphrase, host, port) do
    """
    i=== Add Bookmark ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter the selector to bookmark:\t\t#{host}\t#{port}
    i(Example: /phlog or /fortune)\t\t#{host}\t#{port}
    .
    """
  end

  defp bookmarks_add_title_prompt(_username, _passphrase, selector, host, port) do
    """
    i=== Add Bookmark ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSelector: #{selector}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a title for this bookmark:\t\t#{host}\t#{port}
    .
    """
  end

  defp bookmarks_add(username, passphrase, selector, title, host, port, _ip) do
    # URL decode the selector and passphrase
    selector = URI.decode(selector)
    passphrase = URI.decode(passphrase)
    encoded_pass = URI.encode(passphrase, &URI.char_unreserved?/1)

    case Bookmarks.add(username, passphrase, selector, title) do
      {:ok, bookmark} ->
        """
        i=== Bookmark Added! ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTitle: #{bookmark.title}\t\t#{host}\t#{port}
        iSelector: #{bookmark.selector}\t\t#{host}\t#{port}
        iFolder: #{bookmark.folder}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1View Bookmarks\t/bookmarks/user/#{username}/#{encoded_pass}\t#{host}\t#{port}
        7Add Another\t/bookmarks/add/#{username}/#{encoded_pass}\t#{host}\t#{port}
        .
        """

      {:error, :limit_reached} ->
        error_response("Bookmark limit reached (100 max). Remove some bookmarks first.")

      {:error, :already_exists} ->
        error_response("This selector is already bookmarked.")

      {:error, :invalid_credentials} ->
        error_response("Invalid passphrase.")

      {:error, _} ->
        error_response("Could not add bookmark.")
    end
  end

  defp bookmarks_remove(username, passphrase, bookmark_id, host, port, _ip) do
    passphrase = URI.decode(passphrase)
    encoded_pass = URI.encode(passphrase, &URI.char_unreserved?/1)

    case Bookmarks.remove(username, passphrase, bookmark_id) do
      :ok ->
        """
        i=== Bookmark Removed ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iThe bookmark has been removed.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Bookmarks\t/bookmarks/user/#{username}/#{encoded_pass}\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Bookmark not found.")

      {:error, :invalid_credentials} ->
        error_response("Invalid passphrase.")

      {:error, _} ->
        error_response("Could not remove bookmark.")
    end
  end

  defp bookmarks_folders(username, passphrase, host, port, _ip) do
    passphrase = URI.decode(passphrase)
    encoded_pass = URI.encode(passphrase, &URI.char_unreserved?/1)

    case Bookmarks.folders(username, passphrase) do
      {:ok, folders} ->
        folder_lines = folders
          |> Enum.map(fn f ->
            "1#{f}\t/bookmarks/user/#{username}/#{encoded_pass}/#{f}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== #{username}'s Folders ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{folder_lines}
        i\t\t#{host}\t#{port}
        7Create New Folder\t/bookmarks/newfolder/#{username}/#{encoded_pass}\t#{host}\t#{port}
        1Back to Bookmarks\t/bookmarks/user/#{username}/#{encoded_pass}\t#{host}\t#{port}
        .
        """

      {:error, :invalid_credentials} ->
        error_response("Invalid passphrase.")

      {:error, _} ->
        error_response("Could not retrieve folders.")
    end
  end

  defp bookmarks_newfolder_prompt(_username, _passphrase, host, port) do
    """
    i=== Create Folder ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a name for the new folder:\t\t#{host}\t#{port}
    .
    """
  end

  defp bookmarks_create_folder(username, passphrase, folder_name, host, port, _ip) do
    passphrase = URI.decode(passphrase)
    encoded_pass = URI.encode(passphrase, &URI.char_unreserved?/1)

    case Bookmarks.create_folder(username, passphrase, folder_name) do
      :ok ->
        """
        i=== Folder Created! ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iFolder "#{folder_name}" has been created.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1View Folder\t/bookmarks/user/#{username}/#{encoded_pass}/#{folder_name}\t#{host}\t#{port}
        1Back to Bookmarks\t/bookmarks/user/#{username}/#{encoded_pass}\t#{host}\t#{port}
        .
        """

      {:error, :limit_reached} ->
        error_response("Folder limit reached (10 max).")

      {:error, :already_exists} ->
        error_response("A folder with this name already exists.")

      {:error, :invalid_name} ->
        error_response("Invalid folder name.")

      {:error, :invalid_credentials} ->
        error_response("Invalid passphrase.")

      {:error, _} ->
        error_response("Could not create folder.")
    end
  end

  defp bookmarks_export(username, passphrase, _host, _port, _ip) do
    passphrase = URI.decode(passphrase)

    case Bookmarks.export(username, passphrase) do
      {:ok, export_text} ->
        if export_text == "" do
          """
          No bookmarks to export.

          Add some bookmarks first!
          """
        else
          """
          === #{username}'s Bookmarks Export ===
          Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

          #{export_text}

          === End of Export ===
          """
        end

      {:error, :invalid_credentials} ->
        "Error: Invalid passphrase.\n"

      {:error, _} ->
        "Error exporting bookmarks.\n"
    end
  end

  # === Unit Converter Functions ===

  defp convert_menu(host, port) do
    categories = UnitConverter.categories()

    category_lines = categories
      |> Enum.map(fn cat ->
        units = Enum.join(cat.units, ", ")
        "1#{cat.name}\t/convert/#{String.downcase(cat.name)}\t#{host}\t#{port}\r\n" <>
        "i  Units: #{units}\t\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i=== Unit Converter ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iConvert between various units of measurement.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Quick Convert ---\t\t#{host}\t#{port}
    7Convert (e.g. "100 km to mi")\t/convert\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Categories ---\t\t#{host}\t#{port}
    #{category_lines}
    i\t\t#{host}\t#{port}
    i--- Examples ---\t\t#{host}\t#{port}
    i  100 km to mi\t\t#{host}\t#{port}
    i  32 f to c\t\t#{host}\t#{port}
    i  5 lb to kg\t\t#{host}\t#{port}
    i  1 gal to l\t\t#{host}\t#{port}
    i  1 gb to mb\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp convert_query(query, host, port) do
    query = String.trim(query)

    case UnitConverter.parse_query(query) do
      {:ok, value, from_unit, to_unit} ->
        case UnitConverter.convert(value, from_unit, to_unit) do
          {:ok, result, formatted} ->
            """
            i=== Conversion Result ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            i#{formatted}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iResult: #{format_convert_number(result)}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            7Convert Another\t/convert\t#{host}\t#{port}
            1Back to Converter\t/convert\t#{host}\t#{port}
            .
            """

          {:error, :unknown_units} ->
            error_response("Unknown or incompatible units. Check /convert for supported units.")

          {:error, _} ->
            error_response("Conversion error. Check your input format.")
        end

      {:error, :invalid_format} ->
        """
        i=== Invalid Format ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iCould not parse: #{query}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iFormat: <value> <from> to <to>\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iExamples:\t\t#{host}\t#{port}
        i  100 km to mi\t\t#{host}\t#{port}
        i  32 f to c\t\t#{host}\t#{port}
        i  5 lb to kg\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try Again\t/convert\t#{host}\t#{port}
        1Back to Converter\t/convert\t#{host}\t#{port}
        .
        """
    end
  end

  defp convert_category(category, host, port) do
    category = String.downcase(String.trim(category))

    categories = UnitConverter.categories()
    cat = Enum.find(categories, fn c -> String.downcase(c.name) == category end)

    if cat do
      units_lines = cat.units
        |> Enum.map(fn unit -> "i  #{unit}\t\t#{host}\t#{port}" end)
        |> Enum.join("\r\n")

      """
      i=== #{cat.name} Converter ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      iSupported units:\t\t#{host}\t#{port}
      #{units_lines}
      i\t\t#{host}\t#{port}
      7Convert #{cat.name}\t/convert\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1Back to Converter\t/convert\t#{host}\t#{port}
      .
      """
    else
      error_response("Unknown category: #{category}")
    end
  end

  defp format_convert_number(num) when is_float(num) do
    cond do
      num == Float.round(num, 0) -> :erlang.float_to_binary(num, decimals: 0)
      abs(num) >= 1000 -> :erlang.float_to_binary(num, decimals: 2)
      abs(num) >= 1 -> :erlang.float_to_binary(num, decimals: 4)
      abs(num) >= 0.01 -> :erlang.float_to_binary(num, decimals: 6)
      true -> :erlang.float_to_binary(num, decimals: 10)
    end
  end

  defp format_convert_number(num), do: to_string(num)

  # === Calculator Functions ===

  defp calc_menu(host, port) do
    examples = Calculator.examples()
      |> Enum.map(fn ex -> "i  #{ex}\t\t#{host}\t#{port}" end)
      |> Enum.join("\r\n")

    functions = Calculator.functions()
      |> Enum.map(fn f -> "i  #{f.name} - #{f.description}\t\t#{host}\t#{port}" end)
      |> Enum.join("\r\n")

    constants = Calculator.constants()
      |> Enum.map(fn c -> "i  #{c.name} = #{c.value}\t\t#{host}\t#{port}" end)
      |> Enum.join("\r\n")

    """
    i=== Calculator ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEvaluate mathematical expressions.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Calculate\t/calc\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Examples ---\t\t#{host}\t#{port}
    #{examples}
    i\t\t#{host}\t#{port}
    i--- Operators ---\t\t#{host}\t#{port}
    i  + - * / (basic math)\t\t#{host}\t#{port}
    i  ^ or ** (power)\t\t#{host}\t#{port}
    i  % or mod (modulo)\t\t#{host}\t#{port}
    i  ( ) (grouping)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Functions ---\t\t#{host}\t#{port}
    #{functions}
    i\t\t#{host}\t#{port}
    i--- Constants ---\t\t#{host}\t#{port}
    #{constants}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp calc_evaluate(expr, host, port) do
    expr = String.trim(expr)

    case Calculator.evaluate(expr) do
      {:ok, _result, formatted} ->
        """
        i=== Calculator Result ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{expr} = #{formatted}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iResult: #{formatted}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Calculate Another\t/calc\t#{host}\t#{port}
        1Back to Calculator\t/calc\t#{host}\t#{port}
        .
        """

      {:error, :arithmetic_error} ->
        error_response("Arithmetic error (division by zero?)")

      {:error, :negative_sqrt} ->
        error_response("Cannot take square root of negative number")

      {:error, :invalid_log} ->
        error_response("Logarithm requires a positive number")

      {:error, :mismatched_parentheses} ->
        error_response("Mismatched parentheses")

      {:error, :insufficient_operands} ->
        error_response("Not enough operands for operator")

      {:error, _} ->
        """
        i=== Calculator Error ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iCould not evaluate: #{expr}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTips:\t\t#{host}\t#{port}
        i  - Use spaces between numbers and operators\t\t#{host}\t#{port}
        i  - Check parentheses are balanced\t\t#{host}\t#{port}
        i  - Use valid function names\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try Again\t/calc\t#{host}\t#{port}
        1Back to Calculator\t/calc\t#{host}\t#{port}
        .
        """
    end
  end

  # === Games Functions ===

  defp games_menu(host, port) do
    """
    i=== Simple Games ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPlay classic word and number games!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Available Games ---\t\t#{host}\t#{port}
    1Hangman\t/games/hangman\t#{host}\t#{port}
    i  Guess the word letter by letter\t\t#{host}\t#{port}
    1Number Guess\t/games/number\t#{host}\t#{port}
    i  Guess the secret number (1-100)\t\t#{host}\t#{port}
    1Word Scramble\t/games/scramble\t#{host}\t#{port}
    i  Unscramble the letters\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  # Hangman handlers

  defp hangman_start(session_id, host, port) do
    case Games.start_hangman(session_id) do
      {:ok, game} ->
        """
        i=== Hangman ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iGuess the word letter by letter.\t\t#{host}\t#{port}
        iYou have #{game.remaining} wrong guesses allowed.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iWord: #{game.display}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Guess a letter\t/games/hangman/guess\t#{host}\t#{port}
        1View game state\t/games/hangman/play\t#{host}\t#{port}
        1New game\t/games/hangman\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, _} ->
        error_response("Could not start game.")
    end
  end

  defp hangman_play(session_id, host, port) do
    case Games.hangman_state(session_id) do
      {:ok, game} ->
        guessed = if Enum.empty?(game.guessed_letters), do: "(none)", else: Enum.join(game.guessed_letters, " ")

        status_line = case game.status do
          :won -> "iCongratulations! You won!\t\t#{host}\t#{port}"
          :lost -> "iGame Over! The word was: #{game.word}\t\t#{host}\t#{port}"
          :playing -> "7Guess a letter\t/games/hangman/guess\t#{host}\t#{port}"
        end

        """
        i=== Hangman ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iWord: #{game.display}\t\t#{host}\t#{port}
        iGuessed: #{guessed}\t\t#{host}\t#{port}
        iRemaining guesses: #{game.remaining}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{status_line}
        1New game\t/games/hangman\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, :no_game} ->
        """
        i=== Hangman ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo active game. Start a new one!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/games/hangman\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """
    end
  end

  defp hangman_guess(session_id, letter, host, port) do
    case Games.guess_letter(session_id, letter) do
      {:ok, result} ->
        guessed = Enum.join(result.guessed_letters, " ")
        correct_text = if result.correct, do: "Correct!", else: "Wrong!"

        status_line = case result.status do
          :won -> "iCongratulations! You won!\t\t#{host}\t#{port}"
          :lost -> "iGame Over! The word was: #{result.word}\t\t#{host}\t#{port}"
          :playing -> "7Guess another letter\t/games/hangman/guess\t#{host}\t#{port}"
        end

        """
        i=== Hangman ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iYou guessed: #{result.letter} - #{correct_text}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iWord: #{result.display}\t\t#{host}\t#{port}
        iGuessed letters: #{guessed}\t\t#{host}\t#{port}
        iRemaining guesses: #{result.remaining}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{status_line}
        1New game\t/games/hangman\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, :already_guessed} ->
        error_response("You already guessed that letter!")

      {:error, :invalid_letter} ->
        error_response("Please enter a single letter (a-z)")

      {:error, :game_over, status, word} ->
        result_text = if status == :won, do: "You won!", else: "Game over!"
        """
        i=== Hangman ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{result_text} The word was: #{word}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/games/hangman\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, :no_game} ->
        """
        i=== Hangman ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo active game. Start a new one!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/games/hangman\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """
    end
  end

  # Number Guess handlers

  defp number_guess_start(session_id, host, port) do
    case Games.start_number_guess(session_id, 100) do
      {:ok, game} ->
        """
        i=== Number Guess ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iI'm thinking of a number between 1 and #{game.max}.\t\t#{host}\t#{port}
        iCan you guess what it is?\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Enter your guess\t/games/number/guess\t#{host}\t#{port}
        1View game state\t/games/number/play\t#{host}\t#{port}
        1New game\t/games/number\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, _} ->
        error_response("Could not start game.")
    end
  end

  defp number_guess_play(session_id, host, port) do
    case Games.number_guess_state(session_id) do
      {:ok, game} ->
        guesses_text = if Enum.empty?(game.guesses), do: "(none)", else: Enum.join(game.guesses, ", ")

        status_line = case game.status do
          :won -> "iCongratulations! You got it in #{game.attempts} tries!\t\t#{host}\t#{port}"
          :playing -> "7Enter your guess\t/games/number/guess\t#{host}\t#{port}"
        end

        """
        i=== Number Guess ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iGuessing a number between 1 and #{game.max}\t\t#{host}\t#{port}
        iAttempts: #{game.attempts}\t\t#{host}\t#{port}
        iPrevious guesses: #{guesses_text}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{status_line}
        1New game\t/games/number\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, :no_game} ->
        """
        i=== Number Guess ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo active game. Start a new one!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/games/number\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """
    end
  end

  defp number_guess_guess(session_id, num_str, host, port) do
    case Integer.parse(String.trim(num_str)) do
      {num, ""} ->
        case Games.guess_number(session_id, num) do
          {:ok, result} ->
            hint_text = case result.hint do
              :correct -> "Correct! You got it!"
              :higher -> "Too low! Go higher."
              :lower -> "Too high! Go lower."
            end

            status_line = case result.status do
              :won -> "iCongratulations! You got it in #{result.attempts} tries!\t\t#{host}\t#{port}"
              :playing -> "7Guess again\t/games/number/guess\t#{host}\t#{port}"
            end

            """
            i=== Number Guess ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iYou guessed: #{result.guess}\t\t#{host}\t#{port}
            i#{hint_text}\t\t#{host}\t#{port}
            iAttempts: #{result.attempts}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            #{status_line}
            1New game\t/games/number\t#{host}\t#{port}
            1Back to Games\t/games\t#{host}\t#{port}
            .
            """

          {:error, :already_guessed} ->
            error_response("You already guessed that number!")

          {:error, :invalid_number} ->
            error_response("Please enter a number between 1 and 100")

          {:error, :game_over, _status, secret} ->
            """
            i=== Number Guess ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iGame already over! The number was: #{secret}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Start New Game\t/games/number\t#{host}\t#{port}
            1Back to Games\t/games\t#{host}\t#{port}
            .
            """

          {:error, :no_game} ->
            """
            i=== Number Guess ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iNo active game. Start a new one!\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Start New Game\t/games/number\t#{host}\t#{port}
            1Back to Games\t/games\t#{host}\t#{port}
            .
            """
        end

      _ ->
        error_response("Please enter a valid number")
    end
  end

  # Word Scramble handlers

  defp scramble_start(session_id, host, port) do
    case Games.start_scramble(session_id) do
      {:ok, game} ->
        """
        i=== Word Scramble ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iUnscramble the letters to find the word!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iScrambled: #{game.scrambled}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Enter your guess\t/games/scramble/guess\t#{host}\t#{port}
        1View game state\t/games/scramble/play\t#{host}\t#{port}
        1New game\t/games/scramble\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, _} ->
        error_response("Could not start game.")
    end
  end

  defp scramble_play(session_id, host, port) do
    case Games.scramble_state(session_id) do
      {:ok, game} ->
        status_line = case game.status do
          :won -> "iCongratulations! You got it: #{game.word}\t\t#{host}\t#{port}"
          :playing -> "7Enter your guess\t/games/scramble/guess\t#{host}\t#{port}"
        end

        """
        i=== Word Scramble ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iScrambled: #{game.scrambled}\t\t#{host}\t#{port}
        iAttempts: #{game.attempts}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{status_line}
        1New game\t/games/scramble\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, :no_game} ->
        """
        i=== Word Scramble ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo active game. Start a new one!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/games/scramble\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """
    end
  end

  defp scramble_guess(session_id, word, host, port) do
    case Games.guess_word(session_id, word) do
      {:ok, result} ->
        result_text = if result.correct, do: "Correct!", else: "Not quite..."

        status_line = case result.status do
          :won -> "iThe word was: #{result.word}\t\t#{host}\t#{port}"
          :playing -> "7Try again\t/games/scramble/guess\t#{host}\t#{port}"
        end

        """
        i=== Word Scramble ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iYou guessed: #{result.guess} - #{result_text}\t\t#{host}\t#{port}
        iScrambled: #{result.scrambled}\t\t#{host}\t#{port}
        iAttempts: #{result.attempts}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{status_line}
        1New game\t/games/scramble\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, :game_over, _status, word} ->
        """
        i=== Word Scramble ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iGame already over! The word was: #{word}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/games/scramble\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """

      {:error, :no_game} ->
        """
        i=== Word Scramble ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo active game. Start a new one!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Start New Game\t/games/scramble\t#{host}\t#{port}
        1Back to Games\t/games\t#{host}\t#{port}
        .
        """
    end
  end

  # === Terminal Slides Functions ===

  defp slides_menu(host, port) do
    recent = Slides.list_decks(limit: 5)

    recent_items = if recent == [] do
      "iNo presentations yet. Create one!\t\t#{host}\t#{port}"
    else
      recent
      |> Enum.map(fn deck ->
        slide_count = length(deck.slides)
        "1#{deck.title} (#{slide_count} slides)\t/slides/view/#{deck.id}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")
    end

    """
    i\t\t#{host}\t#{port}
    i  ╔═══════════════════════════════════════════════════════╗\t\t#{host}\t#{port}
    i  ║           TERMINAL SLIDES                             ║\t\t#{host}\t#{port}
    i  ║     Create Beautiful Terminal Presentations           ║\t\t#{host}\t#{port}
    i  ╚═══════════════════════════════════════════════════════╝\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i  Create slide decks with ASCII art, ANSI colors,\t\t#{host}\t#{port}
    i  borders, and beautiful typography. Export to\t\t#{host}\t#{port}
    i  Markdown for use anywhere.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  ACTIONS\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    7Create New Presentation\t/slides/new\t#{host}\t#{port}
    1Browse All Presentations\t/slides/list\t#{host}\t#{port}
    1View Themes\t/slides/themes\t#{host}\t#{port}
    1View Templates\t/slides/templates\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  RECENT PRESENTATIONS\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    #{recent_items}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp slides_list(host, port) do
    decks = Slides.list_decks(limit: 50)

    deck_items = if decks == [] do
      "iNo presentations found.\t\t#{host}\t#{port}"
    else
      decks
      |> Enum.map(fn deck ->
        slide_count = length(deck.slides)
        date = DateTime.to_date(deck.created_at) |> Date.to_string()
        "1#{deck.title} by #{deck.author} (#{slide_count} slides) - #{date}\t/slides/view/#{deck.id}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")
    end

    """
    i\t\t#{host}\t#{port}
    i=== All Presentations ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{deck_items}
    i\t\t#{host}\t#{port}
    7Create New\t/slides/new\t#{host}\t#{port}
    1Back to Slides Menu\t/slides\t#{host}\t#{port}
    .
    """
  end

  defp slides_new_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Create New Presentation ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter: title|author|description|theme\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAvailable themes: #{SlideRenderer.themes() |> Enum.join(", ")}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExample: My Talk|John Doe|A great presentation|tech\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter presentation details\t/slides/new\t#{host}\t#{port}
    1Back to Slides Menu\t/slides\t#{host}\t#{port}
    .
    """
  end

  defp slides_create(input, _ip, host, port) do
    parts = String.split(input, "|") |> Enum.map(&String.trim/1)

    case parts do
      [title, author | rest] when title != "" and author != "" ->
        description = Enum.at(rest, 0, "")
        theme_str = Enum.at(rest, 1, "default")
        theme = String.to_existing_atom(theme_str)

        case Slides.create_deck(title, author, description: description, theme: theme) do
          {:ok, deck} ->
            """
            i\t\t#{host}\t#{port}
            i=== Presentation Created! ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iTitle: #{deck.title}\t\t#{host}\t#{port}
            iAuthor: #{deck.author}\t\t#{host}\t#{port}
            iTheme: #{deck.theme}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iNow add some slides!\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Add Slides\t/slides/edit/#{deck.id}\t#{host}\t#{port}
            1View Presentation\t/slides/view/#{deck.id}\t#{host}\t#{port}
            1Back to Slides Menu\t/slides\t#{host}\t#{port}
            .
            """

          {:error, reason} ->
            """
            i\t\t#{host}\t#{port}
            iError: Failed to create - #{inspect(reason)}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Back to Slides Menu\t/slides\t#{host}\t#{port}
            .
            """
        end

      _ ->
        """
        i\t\t#{host}\t#{port}
        iError: Invalid format. Use: title|author|description|theme\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try Again\t/slides/new\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """
    end
  rescue
    ArgumentError ->
      """
      i\t\t#{host}\t#{port}
      iError: Invalid theme. Use: #{SlideRenderer.themes() |> Enum.join(", ")}\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      7Try Again\t/slides/new\t#{host}\t#{port}
      1Back to Slides Menu\t/slides\t#{host}\t#{port}
      .
      """
  end

  defp slides_view(id, host, port) do
    case Slides.get_deck(id) do
      {:ok, deck} ->
        slide_list = if deck.slides == [] do
          "iNo slides yet. Add some!\t\t#{host}\t#{port}"
        else
          deck.slides
          |> Enum.with_index()
          |> Enum.map(fn {slide, idx} ->
            title = if slide.title != "", do: slide.title, else: "Slide #{idx + 1}"
            "1#{idx + 1}. #{title} (#{slide.type})\t/slides/present/#{id}/#{idx}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")
        end

        """
        i\t\t#{host}\t#{port}
        i=== #{deck.title} ===\t\t#{host}\t#{port}
        iby #{deck.author}\t\t#{host}\t#{port}
        i#{deck.description}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTheme: #{deck.theme} | Slides: #{length(deck.slides)} | Views: #{deck.view_count}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i─────────────────────────────────────────────────────────\t\t#{host}\t#{port}
        i  SLIDES\t\t#{host}\t#{port}
        i─────────────────────────────────────────────────────────\t\t#{host}\t#{port}
        #{slide_list}
        i\t\t#{host}\t#{port}
        i─────────────────────────────────────────────────────────\t\t#{host}\t#{port}
        i  ACTIONS\t\t#{host}\t#{port}
        i─────────────────────────────────────────────────────────\t\t#{host}\t#{port}
        1Start Presentation\t/slides/present/#{id}/0\t#{host}\t#{port}
        1Edit / Add Slides\t/slides/edit/#{id}\t#{host}\t#{port}
        0Export as Markdown\t/slides/export/#{id}/md\t#{host}\t#{port}
        0Export as Plain Text\t/slides/export/#{id}/txt\t#{host}\t#{port}
        1Delete Presentation\t/slides/delete/#{id}\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        """
        i\t\t#{host}\t#{port}
        iError: Presentation not found\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """
    end
  end

  defp slides_present(path, host, port) do
    case String.split(path, "/") do
      [id, idx_str] ->
        case {Slides.get_deck(id), Integer.parse(idx_str)} do
          {{:ok, deck}, {idx, ""}} when idx >= 0 and idx < length(deck.slides) ->
            SlideRenderer.render_for_gopher(deck, idx, host, port)

          {{:ok, deck}, _} ->
            """
            i\t\t#{host}\t#{port}
            iError: Invalid slide number. Deck has #{length(deck.slides)} slides.\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Back to Presentation\t/slides/view/#{id}\t#{host}\t#{port}
            .
            """

          {{:error, :not_found}, _} ->
            """
            i\t\t#{host}\t#{port}
            iError: Presentation not found\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Back to Slides Menu\t/slides\t#{host}\t#{port}
            .
            """
        end

      [id] ->
        # Start from first slide
        slides_present("#{id}/0", host, port)

      _ ->
        """
        i\t\t#{host}\t#{port}
        iError: Invalid presentation path\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """
    end
  end

  defp slides_edit(id, host, port) do
    case Slides.get_deck(id) do
      {:ok, deck} ->
        templates = Slides.templates()
        |> Enum.map(&Atom.to_string/1)
        |> Enum.join(", ")

        """
        i\t\t#{host}\t#{port}
        i=== Edit: #{deck.title} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i  Available slide types:\t\t#{host}\t#{port}
        i  #{templates}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i─────────────────────────────────────────────────────────\t\t#{host}\t#{port}
        i  ADD A SLIDE\t\t#{host}\t#{port}
        i─────────────────────────────────────────────────────────\t\t#{host}\t#{port}
        7Add Title Slide\t/slides/add/#{id}/title\t#{host}\t#{port}
        7Add Content Slide\t/slides/add/#{id}/content\t#{host}\t#{port}
        7Add Code Slide\t/slides/add/#{id}/code\t#{host}\t#{port}
        7Add Quote Slide\t/slides/add/#{id}/quote\t#{host}\t#{port}
        7Add List Slide\t/slides/add/#{id}/list\t#{host}\t#{port}
        7Add Two-Column Slide\t/slides/add/#{id}/two_column\t#{host}\t#{port}
        7Add Image/Art Slide\t/slides/add/#{id}/image\t#{host}\t#{port}
        7Add Comparison Slide\t/slides/add/#{id}/comparison\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1View Presentation\t/slides/view/#{id}\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        """
        i\t\t#{host}\t#{port}
        iError: Presentation not found\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """
    end
  end

  defp slides_add_slide(path, host, port) do
    case String.split(path, "/") do
      [id, type_str] ->
        # Show prompt for content
        type_info = case type_str do
          "title" -> "Enter your main title (will be displayed large and centered)"
          "content" -> "Enter: slide_title|content text"
          "code" -> "Enter: slide_title|your code here"
          "quote" -> "Enter: quote text|attribution"
          "list" -> "Enter: slide_title|item1|item2|item3..."
          "two_column" -> "Enter: slide_title|left content|||right content"
          "image" -> "Enter: slide_title|theme_name (technology, nature, space, etc)"
          "comparison" -> "Enter: slide_title|option1|||option2"
          _ -> "Enter your content"
        end

        """
        i\t\t#{host}\t#{port}
        i=== Add #{String.capitalize(type_str)} Slide ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{type_info}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Enter slide content\t/slides/add/#{id}/#{type_str}/save\t#{host}\t#{port}
        1Cancel\t/slides/edit/#{id}\t#{host}\t#{port}
        .
        """

      [id, type_str, "save\t" <> content] ->
        save_slide(id, type_str, content, host, port)

      [id, type_str, "save " <> content] ->
        save_slide(id, type_str, content, host, port)

      _ ->
        """
        i\t\t#{host}\t#{port}
        iError: Invalid path\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """
    end
  end

  defp save_slide(id, type_str, content, host, port) do
    type = String.to_existing_atom(type_str)

    {title, slide_content, notes} = case type do
      :title ->
        {content, content, ""}

      :quote ->
        case String.split(content, "|") do
          [quote, attr] -> {attr, quote, ""}
          [quote] -> {"", quote, ""}
          _ -> {"", content, ""}
        end

      :list ->
        case String.split(content, "|") do
          [title | items] -> {title, Enum.join(items, "\n"), ""}
          _ -> {"", content, ""}
        end

      _ ->
        case String.split(content, "|", parts: 2) do
          [title, body] -> {title, body, ""}
          [body] -> {"", body, ""}
        end
    end

    case Slides.add_slide(id, type, slide_content, title: title, notes: notes) do
      {:ok, deck} ->
        """
        i\t\t#{host}\t#{port}
        i=== Slide Added! ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iYour presentation now has #{length(deck.slides)} slides.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Add Another Slide\t/slides/edit/#{id}\t#{host}\t#{port}
        1View Presentation\t/slides/view/#{id}\t#{host}\t#{port}
        1Preview This Slide\t/slides/present/#{id}/#{length(deck.slides) - 1}\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        iError: Failed to add slide - #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Edit\t/slides/edit/#{id}\t#{host}\t#{port}
        .
        """
    end
  rescue
    ArgumentError ->
      """
      i\t\t#{host}\t#{port}
      iError: Invalid slide type\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1Back to Slides Menu\t/slides\t#{host}\t#{port}
      .
      """
  end

  defp slides_export(path, host, port) do
    case String.split(path, "/") do
      [id, "md"] ->
        case Slides.export_markdown(id) do
          {:ok, markdown} ->
            format_text_response(markdown, host, port)

          {:error, :not_found} ->
            """
            i\t\t#{host}\t#{port}
            iError: Presentation not found\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Back to Slides Menu\t/slides\t#{host}\t#{port}
            .
            """
        end

      [id, "txt"] ->
        case Slides.export_text(id) do
          {:ok, text} ->
            format_text_response(text, host, port)

          {:error, :not_found} ->
            """
            i\t\t#{host}\t#{port}
            iError: Presentation not found\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Back to Slides Menu\t/slides\t#{host}\t#{port}
            .
            """
        end

      [id] ->
        # Show export options
        """
        i\t\t#{host}\t#{port}
        i=== Export Presentation ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        0Export as Markdown (.md)\t/slides/export/#{id}/md\t#{host}\t#{port}
        0Export as Plain Text (.txt)\t/slides/export/#{id}/txt\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Presentation\t/slides/view/#{id}\t#{host}\t#{port}
        .
        """

      _ ->
        """
        i\t\t#{host}\t#{port}
        iError: Invalid export path\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """
    end
  end

  defp slides_delete(id, host, port) do
    case Slides.delete_deck(id) do
      :ok ->
        """
        i\t\t#{host}\t#{port}
        i=== Presentation Deleted ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iThe presentation has been removed.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        """
        i\t\t#{host}\t#{port}
        iError: Presentation not found\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Slides Menu\t/slides\t#{host}\t#{port}
        .
        """
    end
  end

  defp slides_themes(host, port) do
    themes = SlideRenderer.themes()
    |> Enum.map(fn theme ->
      "i  - #{theme}\t\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Presentation Themes ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAvailable themes for your presentations:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{themes}
    i\t\t#{host}\t#{port}
    iThemes control colors, borders, and styling.\t\t#{host}\t#{port}
    iSpecify theme when creating a presentation.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Slides Menu\t/slides\t#{host}\t#{port}
    .
    """
  end

  defp slides_templates(host, port) do
    templates = [
      {"title", "Large centered title slide"},
      {"content", "Text content with optional title"},
      {"code", "Code block with syntax styling"},
      {"quote", "Blockquote with attribution"},
      {"list", "Bulleted list items"},
      {"two_column", "Side-by-side content"},
      {"image", "ASCII/ANSI art display"},
      {"comparison", "VS-style comparison"}
    ]

    template_items = templates
    |> Enum.map(fn {name, desc} ->
      "i  #{String.pad_trailing(name, 12)} - #{desc}\t\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Slide Templates ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAvailable slide types:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{template_items}
    i\t\t#{host}\t#{port}
    iEach template has its own input format.\t\t#{host}\t#{port}
    iSee examples when adding slides.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Slides Menu\t/slides\t#{host}\t#{port}
    .
    """
  end

  # === AI Writing Assistant Functions ===

  defp write_menu(host, port) do
    """
    i\t\t#{host}\t#{port}
    i  ╔═══════════════════════════════════════════════════════╗\t\t#{host}\t#{port}
    i  ║           AI WRITING ASSISTANT                        ║\t\t#{host}\t#{port}
    i  ║     Draft, Improve, and Polish Your Writing           ║\t\t#{host}\t#{port}
    i  ╚═══════════════════════════════════════════════════════╝\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i  Let AI help you with your writing! Generate drafts,\t\t#{host}\t#{port}
    i  improve existing content, proofread, and more.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  CREATE & GENERATE\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    7Draft from Topic\t/write/draft\t#{host}\t#{port}
    7Generate Outline\t/write/outline\t#{host}\t#{port}
    7Generate Titles\t/write/titles\t#{host}\t#{port}
    7Generate Tags\t/write/tags\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  IMPROVE & POLISH\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    7Improve Writing\t/write/improve\t#{host}\t#{port}
    7Proofread\t/write/proofread\t#{host}\t#{port}
    7Generate Introduction\t/write/intro\t#{host}\t#{port}
    7Generate Conclusion\t/write/conclusion\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  RESIZE & TRANSFORM\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    7Expand Content\t/write/expand\t#{host}\t#{port}
    7Compress Content\t/write/compress\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  REFERENCES\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    1Writing Tones\t/write/tones\t#{host}\t#{port}
    1Writing Styles\t/write/styles\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp write_draft_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Draft from Topic ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a topic or outline to generate a draft.\t\t#{host}\t#{port}
    iExample: "benefits of remote work"\t\t#{host}\t#{port}
    iExample: "1. intro 2. history 3. benefits 4. conclusion"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Topic or Outline\t/write/draft\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_draft(topic, host, port) do
    topic = String.trim(topic)

    case WritingAssistant.draft(topic) do
      {:ok, draft} ->
        formatted = format_text_as_info(draft, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Generated Draft ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTopic: #{truncate(topic, 50)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Generate Another Draft\t/write/draft\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating draft: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_improve_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Improve Writing ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your text and AI will improve its style,\t\t#{host}\t#{port}
    iclarity, flow, and engagement.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Text to Improve\t/write/improve\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_improve(content, host, port) do
    content = String.trim(content)

    case WritingAssistant.improve(content) do
      {:ok, improved} ->
        formatted = format_text_as_info(improved, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Improved Version ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Improve More Text\t/write/improve\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error improving text: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_proofread_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Proofread ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your text and AI will check for:\t\t#{host}\t#{port}
    i  - Grammar errors\t\t#{host}\t#{port}
    i  - Spelling mistakes\t\t#{host}\t#{port}
    i  - Punctuation issues\t\t#{host}\t#{port}
    i  - Awkward phrasing\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Text to Proofread\t/write/proofread\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_proofread(content, host, port) do
    content = String.trim(content)

    case WritingAssistant.proofread(content) do
      {:ok, proofread} ->
        formatted = format_text_as_info(proofread, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Proofread Result ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Proofread More Text\t/write/proofread\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error proofreading: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_tone_prompt(tone, host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Adjust Tone to: #{tone} ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your text and AI will rewrite it\t\t#{host}\t#{port}
    iin a #{tone} tone.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Text to Adjust\t/write/tone/#{tone}\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Tones List\t/write/tones\t#{host}\t#{port}
    .
    """
  end

  defp write_titles_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Generate Titles ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your content and AI will suggest\t\t#{host}\t#{port}
    i5 compelling title options.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Content\t/write/titles\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_titles(content, host, port) do
    content = String.trim(content)

    case WritingAssistant.generate_titles(content) do
      {:ok, titles} ->
        title_lines = titles
        |> Enum.with_index(1)
        |> Enum.map(fn {title, idx} ->
          "i  #{idx}. #{title}\t\t#{host}\t#{port}"
        end)
        |> Enum.join("\r\n")

        """
        i\t\t#{host}\t#{port}
        i=== Title Suggestions ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{title_lines}
        i\t\t#{host}\t#{port}
        7Generate for Different Content\t/write/titles\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating titles: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_tags_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Generate Tags ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your content and AI will suggest\t\t#{host}\t#{port}
    irelevant tags and keywords.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Content\t/write/tags\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_tags(content, host, port) do
    content = String.trim(content)

    case WritingAssistant.generate_tags(content) do
      {:ok, tags} ->
        tag_line = tags |> Enum.join(", ")

        """
        i\t\t#{host}\t#{port}
        i=== Suggested Tags ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{tag_line}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Generate for Different Content\t/write/tags\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating tags: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_expand_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Expand Content ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your text and AI will expand it\t\t#{host}\t#{port}
    iwith more details, examples, and context.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Content to Expand\t/write/expand\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_expand(content, host, port) do
    content = String.trim(content)

    case WritingAssistant.expand(content) do
      {:ok, expanded} ->
        formatted = format_text_as_info(expanded, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Expanded Version ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Expand More Content\t/write/expand\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error expanding content: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_compress_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Compress Content ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your text and AI will make it\t\t#{host}\t#{port}
    imore concise while keeping key points.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Content to Compress\t/write/compress\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_compress(content, host, port) do
    content = String.trim(content)

    case WritingAssistant.compress(content) do
      {:ok, compressed} ->
        formatted = format_text_as_info(compressed, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Compressed Version ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Compress More Content\t/write/compress\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error compressing content: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_outline_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Generate Outline ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a topic and AI will create\t\t#{host}\t#{port}
    ia detailed outline for your article.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Topic\t/write/outline\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_outline(topic, host, port) do
    topic = String.trim(topic)

    case WritingAssistant.outline(topic) do
      {:ok, outline} ->
        formatted = format_text_as_info(outline, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Outline: #{truncate(topic, 40)} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Generate for Another Topic\t/write/outline\t#{host}\t#{port}
        7Draft from This Topic\t/write/draft\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating outline: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_intro_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Generate Introduction ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your content and AI will write\t\t#{host}\t#{port}
    ian engaging introduction for it.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Content\t/write/intro\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_intro(content, host, port) do
    content = String.trim(content)

    case WritingAssistant.introduce(content) do
      {:ok, intro} ->
        formatted = format_text_as_info(intro, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Generated Introduction ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Generate for Different Content\t/write/intro\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating introduction: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_conclusion_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Generate Conclusion ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your content and AI will write\t\t#{host}\t#{port}
    ia fitting conclusion for it.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Content\t/write/conclusion\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_conclusion(content, host, port) do
    content = String.trim(content)

    case WritingAssistant.conclude(content) do
      {:ok, conclusion} ->
        formatted = format_text_as_info(conclusion, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Generated Conclusion ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Generate for Different Content\t/write/conclusion\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating conclusion: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Writing Menu\t/write\t#{host}\t#{port}
        .
        """
    end
  end

  defp write_tones_list(host, port) do
    tones = WritingAssistant.tones()

    tone_descriptions = %{
      formal: "Professional, polished language",
      casual: "Conversational, approachable style",
      technical: "Precise, detailed explanations",
      friendly: "Warm, personable communication",
      professional: "Balanced, authoritative voice",
      creative: "Expressive, unique writing"
    }

    tone_items = tones
    |> Enum.map(fn tone ->
      desc = Map.get(tone_descriptions, tone, "")
      "i  #{String.pad_trailing(Atom.to_string(tone), 14)} #{desc}\t\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Writing Tones ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAvailable tones for adjusting your writing:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{tone_items}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  defp write_styles_list(host, port) do
    styles = WritingAssistant.styles()

    style_descriptions = %{
      academic: "Scholarly, research-oriented",
      blog: "Engaging web content",
      news: "Journalistic, factual reporting",
      story: "Narrative, storytelling style",
      tutorial: "Step-by-step instructions",
      review: "Evaluative, critical analysis"
    }

    style_items = styles
    |> Enum.map(fn style ->
      desc = Map.get(style_descriptions, style, "")
      "i  #{String.pad_trailing(Atom.to_string(style), 14)} #{desc}\t\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Writing Styles ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAvailable styles for drafting content:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{style_items}
    i\t\t#{host}\t#{port}
    1Back to Writing Menu\t/write\t#{host}\t#{port}
    .
    """
  end

  # === AI Semantic Search Functions ===

  defp semantic_menu(host, port) do
    """
    i\t\t#{host}\t#{port}
    i  ╔═══════════════════════════════════════════════════════╗\t\t#{host}\t#{port}
    i  ║           AI SEMANTIC SEARCH                          ║\t\t#{host}\t#{port}
    i  ║     Find Content by Meaning, Not Just Keywords        ║\t\t#{host}\t#{port}
    i  ╚═══════════════════════════════════════════════════════╝\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i  Use natural language to find what you're looking for.\t\t#{host}\t#{port}
    i  AI understands the meaning behind your queries.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  SEARCH\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    7Search All Content\t/semantic/search\t#{host}\t#{port}
    1View Trending Topics\t/semantic/trending\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  INFO\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    1Content Types\t/semantic/types\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i  TIP: Try natural queries like:\t\t#{host}\t#{port}
    i    "articles about technology trends"\t\t#{host}\t#{port}
    i    "posts discussing privacy"\t\t#{host}\t#{port}
    i    "content related to retro computing"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp semantic_search_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Semantic Search ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your query in natural language.\t\t#{host}\t#{port}
    iAI will find content matching the meaning.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i  "recent discussions about open source"\t\t#{host}\t#{port}
    i  "tutorials on programming"\t\t#{host}\t#{port}
    i  "philosophical thoughts"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Search Query\t/semantic/search\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
    .
    """
  end

  defp semantic_search(query, host, port) do
    query = String.trim(query)

    case SemanticSearch.search(query, limit: 15) do
      {:ok, []} ->
        """
        i\t\t#{host}\t#{port}
        i=== Search Results ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo results found for: "#{truncate(query, 40)}"\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTry different keywords or phrasing.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try Another Search\t/semantic/search\t#{host}\t#{port}
        1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
        .
        """

      {:ok, results} ->
        result_lines = results
        |> Enum.with_index(1)
        |> Enum.map(fn {result, idx} ->
          type_label = result.type |> Atom.to_string() |> String.capitalize()
          score_pct = Float.round(result.score * 100, 0) |> trunc()
          excerpt = truncate(result.excerpt, 60)
          link = result_link(result, host, port)

          """
          i#{idx}. [#{type_label}] #{result.title} (#{score_pct}% match)\t\t#{host}\t#{port}
          i   #{excerpt}\t\t#{host}\t#{port}
          #{link}
          i\t\t#{host}\t#{port}
          """
        end)
        |> Enum.join("")

        """
        i\t\t#{host}\t#{port}
        i=== Search Results for "#{truncate(query, 30)}" ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iFound #{length(results)} result(s)\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{result_lines}
        7Search Again\t/semantic/search\t#{host}\t#{port}
        1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
        .
        """
    end
  end

  defp semantic_similar(path, host, port) do
    # Parse type/id from path
    case String.split(path, "/", parts: 2) do
      [type_str, id] ->
        type = String.to_existing_atom(type_str)

        case SemanticSearch.find_similar(type, id, limit: 10) do
          {:ok, []} ->
            """
            i\t\t#{host}\t#{port}
            i=== Similar Content ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iNo similar content found.\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
            .
            """

          {:ok, similar} ->
            similar_lines = similar
            |> Enum.with_index(1)
            |> Enum.map(fn {item, idx} ->
              type_label = item.type |> Atom.to_string() |> String.capitalize()
              score_pct = Float.round(item.score * 100, 0) |> trunc()
              link = result_link(item, host, port)

              """
              i#{idx}. [#{type_label}] #{item.title} (#{score_pct}% similar)\t\t#{host}\t#{port}
              #{link}
              """
            end)
            |> Enum.join("")

            """
            i\t\t#{host}\t#{port}
            i=== Similar Content ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            #{similar_lines}
            i\t\t#{host}\t#{port}
            1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
            .
            """

          {:error, reason} ->
            """
            i\t\t#{host}\t#{port}
            3Error: #{inspect(reason)}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
            .
            """
        end

      _ ->
        """
        i\t\t#{host}\t#{port}
        3Invalid path format. Use: /semantic/similar/<type>/<id>\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
        .
        """
    end
  rescue
    ArgumentError ->
      """
      i\t\t#{host}\t#{port}
      3Unknown content type\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
      .
      """
  end

  defp semantic_trending(host, port) do
    case SemanticSearch.trending_topics(limit: 10, days: 7) do
      {:ok, []} ->
        """
        i\t\t#{host}\t#{port}
        i=== Trending Topics ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo trending topics found.\t\t#{host}\t#{port}
        iAdd more content to see trends!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
        .
        """

      {:ok, topics} ->
        topic_lines = topics
        |> Enum.with_index(1)
        |> Enum.map(fn {topic, idx} ->
          desc = if topic.description != "", do: " - #{topic.description}", else: ""
          "i  #{idx}. #{topic.topic}#{desc}\t\t#{host}\t#{port}"
        end)
        |> Enum.join("\r\n")

        """
        i\t\t#{host}\t#{port}
        i=== Trending Topics (Last 7 Days) ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{topic_lines}
        i\t\t#{host}\t#{port}
        1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
        .
        """
    end
  end

  defp semantic_types(host, port) do
    types = SemanticSearch.content_types()

    type_descriptions = %{
      phlog: "Blog posts and articles",
      document: "Uploaded documents and files",
      post: "Bulletin board discussions",
      guestbook: "Guestbook entries",
      user_phlog: "User-submitted blog posts"
    }

    type_lines = types
    |> Enum.map(fn type ->
      desc = Map.get(type_descriptions, type, "")
      "i  #{String.pad_trailing(Atom.to_string(type), 12)} #{desc}\t\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Content Types ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSemantic search covers these content types:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{type_lines}
    i\t\t#{host}\t#{port}
    1Back to Semantic Menu\t/semantic\t#{host}\t#{port}
    .
    """
  end

  defp result_link(result, host, port) do
    case result.type do
      :phlog -> "1View Entry\t/phlog/entry/#{result.path || result.id}\t#{host}\t#{port}"
      :document -> "1View Document\t/docs/view/#{result.id}\t#{host}\t#{port}"
      :post -> "1View Post\t/board/post/#{result.id}\t#{host}\t#{port}"
      :guestbook -> "1View Guestbook\t/guestbook\t#{host}\t#{port}"
      :user_phlog -> "1View Post\t/phlog/user/#{result.author}/#{result.id}\t#{host}\t#{port}"
      _ -> "i(No direct link)\t\t#{host}\t#{port}"
    end
  end

  # === AI Creative Writing Studio Functions ===

  defp creative_menu(host, port) do
    """
    i\t\t#{host}\t#{port}
    i  ╔═══════════════════════════════════════════════════════╗\t\t#{host}\t#{port}
    i  ║           AI CREATIVE WRITING STUDIO                  ║\t\t#{host}\t#{port}
    i  ║        Stories, Poems, Lyrics, and More               ║\t\t#{host}\t#{port}
    i  ╚═══════════════════════════════════════════════════════╝\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i  Let your imagination run wild! Generate creative content\t\t#{host}\t#{port}
    i  from stories to poetry to song lyrics.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  CREATIVE WRITING\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    7Write a Story\t/creative/story\t#{host}\t#{port}
    7Write a Poem\t/creative/poem\t#{host}\t#{port}
    7Write Song Lyrics\t/creative/lyrics\t#{host}\t#{port}
    7Continue a Story\t/creative/continue\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  WORLDBUILDING\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    7Create a Character\t/creative/character\t#{host}\t#{port}
    7Build a World\t/creative/world\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  INSPIRATION\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    1Get Writing Prompts\t/creative/prompts\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i  REFERENCES\t\t#{host}\t#{port}
    i═══════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    1Story Genres\t/creative/genres\t#{host}\t#{port}
    1Poem Types\t/creative/poem-types\t#{host}\t#{port}
    1Moods & Tones\t/creative/moods\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp creative_story_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Write a Story ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a story prompt and AI will write a short story.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i  "A detective finds a mysterious letter"\t\t#{host}\t#{port}
    i  "Two strangers meet on a train"\t\t#{host}\t#{port}
    i  "A witch discovers she's lost her powers"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Story Prompt\t/creative/story\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_story(prompt, host, port) do
    prompt = String.trim(prompt)

    case CreativeStudio.story(prompt) do
      {:ok, story} ->
        formatted = format_text_as_info(story, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Your Story ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iPrompt: #{truncate(prompt, 50)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Write Another Story\t/creative/story\t#{host}\t#{port}
        7Continue This Story\t/creative/continue\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating story: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """
    end
  end

  defp creative_poem_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Write a Poem ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a topic for your poem.\t\t#{host}\t#{port}
    iDefault style: free verse\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i  "autumn leaves"\t\t#{host}\t#{port}
    i  "first love"\t\t#{host}\t#{port}
    i  "the ocean at midnight"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Poem Topic\t/creative/poem\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1View Poem Types\t/creative/poem-types\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_poem(topic, host, port) do
    topic = String.trim(topic)

    case CreativeStudio.poem(topic) do
      {:ok, poem} ->
        formatted = format_text_as_info(poem, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Your Poem ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTopic: #{truncate(topic, 50)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Write Another Poem\t/creative/poem\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating poem: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """
    end
  end

  defp creative_lyrics_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Write Song Lyrics ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a theme for your song lyrics.\t\t#{host}\t#{port}
    iDefault style: pop\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i  "heartbreak and moving on"\t\t#{host}\t#{port}
    i  "summer road trip adventure"\t\t#{host}\t#{port}
    i  "finding yourself"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Song Theme\t/creative/lyrics\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1View Moods\t/creative/moods\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_lyrics(theme, host, port) do
    theme = String.trim(theme)

    case CreativeStudio.lyrics(theme) do
      {:ok, lyrics} ->
        formatted = format_text_as_info(lyrics, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Your Song Lyrics ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTheme: #{truncate(theme, 50)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Write More Lyrics\t/creative/lyrics\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating lyrics: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """
    end
  end

  defp creative_continue_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Continue a Story ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste the beginning of your story and AI will\t\t#{host}\t#{port}
    icontinue it for you.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Story So Far\t/creative/continue\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_continue(story_so_far, host, port) do
    story_so_far = String.trim(story_so_far)

    case CreativeStudio.continue_story(story_so_far) do
      {:ok, continuation} ->
        formatted = format_text_as_info(continuation, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Story Continuation ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Continue Further\t/creative/continue\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error continuing story: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """
    end
  end

  defp creative_rewrite_prompt(style, host, port) do
    # Validate style exists as atom (will raise if invalid)
    _style_atom = String.to_existing_atom(style)
    """
    i\t\t#{host}\t#{port}
    i=== Rewrite in #{style} Style ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste your content and AI will rewrite it\t\t#{host}\t#{port}
    iin the #{style} genre style.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Content to Rewrite\t/creative/rewrite/#{style}\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1View All Genres\t/creative/genres\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  rescue
    _ ->
      """
      i\t\t#{host}\t#{port}
      3Unknown style: #{style}\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1View Available Genres\t/creative/genres\t#{host}\t#{port}
      1Back to Creative Menu\t/creative\t#{host}\t#{port}
      .
      """
  end

  defp creative_prompts(host, port) do
    categories = [:fantasy, :scifi, :romance, :horror, :mystery, :slice_of_life]

    category_lines = categories
    |> Enum.map(fn cat ->
      name = cat |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
      "1#{name} Prompts\t/creative/prompts/#{cat}\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Writing Prompts ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iGet AI-generated writing prompts for inspiration!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- By Category ---\t\t#{host}\t#{port}
    #{category_lines}
    i\t\t#{host}\t#{port}
    1Random Prompts\t/creative/prompts/general\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_prompts_category(category, host, port) do
    category_atom = String.to_existing_atom(category)

    case CreativeStudio.generate_prompts(category_atom, 5) do
      {:ok, prompts} ->
        prompt_lines = prompts
        |> Enum.with_index(1)
        |> Enum.map(fn {prompt, idx} ->
          "i  #{idx}. #{truncate(prompt, 65)}\t\t#{host}\t#{port}"
        end)
        |> Enum.join("\r\n")

        category_name = category |> String.replace("_", " ") |> String.capitalize()

        """
        i\t\t#{host}\t#{port}
        i=== #{category_name} Writing Prompts ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{prompt_lines}
        i\t\t#{host}\t#{port}
        1Generate More Prompts\t/creative/prompts/#{category}\t#{host}\t#{port}
        1All Categories\t/creative/prompts\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error generating prompts: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """
    end
  rescue
    _ ->
      creative_prompts_category("general", host, port)
  end

  defp creative_character_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Create a Character ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter character traits and AI will create\t\t#{host}\t#{port}
    ia detailed character profile.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i  "brave, curious, has a secret"\t\t#{host}\t#{port}
    i  "cynical detective with a soft spot for strays"\t\t#{host}\t#{port}
    i  "young wizard, impatient, brilliant"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter Character Traits\t/creative/character\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_character(traits, host, port) do
    traits = String.trim(traits)

    case CreativeStudio.character(traits) do
      {:ok, profile} ->
        formatted = format_text_as_info(profile, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== Character Profile ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTraits: #{truncate(traits, 50)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Create Another Character\t/creative/character\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error creating character: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """
    end
  end

  defp creative_world_prompt(host, port) do
    """
    i\t\t#{host}\t#{port}
    i=== Build a World ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a concept and AI will create a detailed\t\t#{host}\t#{port}
    iworld/setting description.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExamples:\t\t#{host}\t#{port}
    i  "floating islands connected by bridges"\t\t#{host}\t#{port}
    i  "post-apocalyptic underground city"\t\t#{host}\t#{port}
    i  "enchanted forest with sentient trees"\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter World Concept\t/creative/world\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_world(concept, host, port) do
    concept = String.trim(concept)

    case CreativeStudio.worldbuild(concept) do
      {:ok, world} ->
        formatted = format_text_as_info(world, host, port)
        """
        i\t\t#{host}\t#{port}
        i=== World Description ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iConcept: #{truncate(concept, 50)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted}
        i\t\t#{host}\t#{port}
        7Build Another World\t/creative/world\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        """
        i\t\t#{host}\t#{port}
        3Error building world: #{inspect(reason)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Creative Menu\t/creative\t#{host}\t#{port}
        .
        """
    end
  end

  defp creative_genres(host, port) do
    genres = CreativeStudio.genres()

    genre_lines = genres
    |> Enum.map(fn genre ->
      name = genre |> Atom.to_string() |> String.capitalize()
      "1Rewrite as #{name}\t/creative/rewrite/#{genre}\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Story Genres ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAvailable genres for stories and rewrites:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{genre_lines}
    i\t\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_poem_types(host, port) do
    poem_types = CreativeStudio.poem_types()

    type_descriptions = %{
      haiku: "5-7-5 syllables, 3 lines, Japanese",
      sonnet: "14 lines, iambic pentameter, ABAB rhyme",
      limerick: "5 lines, AABBA rhyme, humorous",
      free_verse: "No strict meter or rhyme",
      acrostic: "First letters spell a word",
      ballad: "Narrative with rhythm and refrain"
    }

    type_lines = poem_types
    |> Enum.map(fn type ->
      name = type |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
      desc = Map.get(type_descriptions, type, "")
      "i  #{String.pad_trailing(name, 12)} #{desc}\t\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Poem Types ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{type_lines}
    i\t\t#{host}\t#{port}
    7Write a Poem\t/creative/poem\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  defp creative_moods(host, port) do
    moods = CreativeStudio.moods()

    mood_lines = moods
    |> Enum.map(fn mood ->
      name = mood |> Atom.to_string() |> String.capitalize()
      "i  - #{name}\t\t#{host}\t#{port}"
    end)
    |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== Moods & Tones ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAvailable moods for creative writing:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{mood_lines}
    i\t\t#{host}\t#{port}
    7Write Song Lyrics\t/creative/lyrics\t#{host}\t#{port}
    1Back to Creative Menu\t/creative\t#{host}\t#{port}
    .
    """
  end

  # === Link Directory Functions ===

  defp links_menu(host, port) do
    {:ok, categories} = LinkDirectory.list_categories()
    {:ok, stats} = LinkDirectory.stats()

    category_lines = categories
      |> Enum.map(fn cat ->
        "1#{cat.name} (#{cat.count})\t/links/category/#{cat.id}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i=== Link Directory ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iCurated links to Gopher and Gemini sites.\t\t#{host}\t#{port}
    iTotal links: #{stats.total}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Categories ---\t\t#{host}\t#{port}
    #{category_lines}
    i\t\t#{host}\t#{port}
    i--- Actions ---\t\t#{host}\t#{port}
    7Search Links\t/links/search\t#{host}\t#{port}
    7Submit a Link\t/links/submit\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp handle_links_category(category, host, port) do
    case LinkDirectory.get_category(category) do
      {:ok, %{info: info, links: links}} ->
        link_lines = links
          |> Enum.map(fn link ->
            type = gopher_type_for_url(link.url)
            desc = if link.description, do: " - #{truncate(link.description, 50)}", else: ""
            "#{type}#{link.title}#{desc}\t#{link.url}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== #{info.name} ===\t\t#{host}\t#{port}
        i#{info.description}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{length(links)} link(s) in this category:\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{link_lines}
        i\t\t#{host}\t#{port}
        1Back to Directory\t/links\t#{host}\t#{port}
        .
        """

      {:error, :category_not_found} ->
        error_response("Category not found: #{category}")
    end
  end

  defp links_submit_prompt(host, port) do
    """
    iSubmit a Link\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: URL | Title | Category\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iCategories:\t\t#{host}\t#{port}
    igopher, gemini, tech, retro, programming, art, writing, games, misc\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExample:\t\t#{host}\t#{port}
    igopher://example.com | My Cool Server | gopher\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSubmitted links are reviewed before appearing.\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_links_submit(input, host, port, ip) do
    case String.split(input, "|") |> Enum.map(&String.trim/1) do
      [url, title, category] when url != "" and title != "" and category != "" ->
        case LinkDirectory.submit_link(url, title, category, nil, ip) do
          {:ok, _id} ->
            format_text_response("""
            === Link Submitted ===

            Thank you for your submission!

            URL: #{url}
            Title: #{title}
            Category: #{category}

            Your link will be reviewed and approved soon.
            """, host, port)

          {:error, :invalid_category} ->
            error_response("Invalid category. Valid: gopher, gemini, tech, retro, programming, art, writing, games, misc")
        end

      _ ->
        error_response("Invalid format. Use: URL | Title | Category")
    end
  end

  defp links_search_prompt(host, port) do
    """
    iSearch Links\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a keyword to search:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_links_search(query, host, port) do
    query = String.trim(query)

    case LinkDirectory.search(query) do
      {:ok, []} ->
        format_text_response("""
        === Search Results for "#{query}" ===

        No links found matching "#{query}".

        Try a different search term.
        """, host, port)

      {:ok, results} ->
        result_lines = results
          |> Enum.take(20)
          |> Enum.map(fn link ->
            desc = if link.description, do: "\n  #{truncate(link.description, 60)}", else: ""
            "[#{link.category}] #{link.title}#{desc}\n  #{link.url}"
          end)
          |> Enum.join("\n\n")

        format_text_response("""
        === Search Results for "#{query}" ===

        Found #{length(results)} link(s):

        #{result_lines}
        """, host, port)
    end
  end

  defp gopher_type_for_url(url) do
    cond do
      String.starts_with?(url, "gopher://") -> "1"
      String.starts_with?(url, "gemini://") -> "h"
      String.starts_with?(url, "http") -> "h"
      true -> "1"
    end
  end

  # === Bulletin Board Functions ===

  defp board_menu(host, port) do
    {:ok, boards} = BulletinBoard.list_boards()
    {:ok, stats} = BulletinBoard.stats()

    board_lines = boards
      |> Enum.map(fn b ->
        activity = if b.last_activity, do: " [#{format_date(b.last_activity)}]", else: ""
        "1#{b.name} (#{b.thread_count} threads)#{activity}\t/board/#{b.id}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i=== Bulletin Board ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iCommunity discussion boards.\t\t#{host}\t#{port}
    iTotal: #{stats.total_threads} threads, #{stats.total_replies} replies\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Boards ---\t\t#{host}\t#{port}
    #{board_lines}
    i\t\t#{host}\t#{port}
    0Recent Posts\t/board/recent\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp handle_board_list(board_id, host, port) do
    case BulletinBoard.get_board(board_id) do
      {:ok, %{info: info, threads: threads, total: total}} ->
        thread_lines = if threads == [] do
          "iNo threads yet. Be the first to post!\t\t#{host}\t#{port}"
        else
          threads
          |> Enum.map(fn t ->
            _date = format_date(t.created_at)
            replies = if t.reply_count > 0, do: " (#{t.reply_count} replies)", else: ""
            "1#{t.title} - #{t.author}#{replies}\t/board/#{board_id}/thread/#{t.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")
        end

        """
        i=== #{info.name} ===\t\t#{host}\t#{port}
        i#{info.description}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{total} thread(s)\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{thread_lines}
        i\t\t#{host}\t#{port}
        7Start New Thread\t/board/#{board_id}/new\t#{host}\t#{port}
        1Back to Boards\t/board\t#{host}\t#{port}
        .
        """

      {:error, :board_not_found} ->
        error_response("Board not found: #{board_id}")
    end
  end

  defp handle_board_thread(board_id, thread_id, host, port) do
    case BulletinBoard.get_thread(board_id, thread_id) do
      {:ok, %{thread: thread, replies: replies}} ->
        reply_lines = if replies == [] do
          "iNo replies yet.\t\t#{host}\t#{port}"
        else
          replies
          |> Enum.with_index(1)
          |> Enum.map(fn {r, i} ->
            date = format_date(r.created_at)
            body_lines = r.body
              |> String.split("\n")
              |> Enum.take(5)
              |> Enum.map(fn line -> "i  #{line}\t\t#{host}\t#{port}" end)
              |> Enum.join("\r\n")

            """
            i\t\t#{host}\t#{port}
            i[#{i}] #{r.author} - #{date}\t\t#{host}\t#{port}
            #{body_lines}
            """
          end)
          |> Enum.join("\r\n")
        end

        body_lines = thread.body
          |> String.split("\n")
          |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")

        """
        i=== #{thread.title} ===\t\t#{host}\t#{port}
        iBy #{thread.author} - #{format_date(thread.created_at)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{body_lines}
        i\t\t#{host}\t#{port}
        i--- Replies (#{length(replies)}) ---\t\t#{host}\t#{port}
        #{reply_lines}
        i\t\t#{host}\t#{port}
        7Reply to Thread\t/board/#{board_id}/reply/#{thread_id}\t#{host}\t#{port}
        1Back to Board\t/board/#{board_id}\t#{host}\t#{port}
        .
        """

      {:error, :board_not_found} ->
        error_response("Board not found")

      {:error, :thread_not_found} ->
        error_response("Thread not found")
    end
  end

  defp board_new_thread_prompt(board_id, host, port) do
    """
    iStart New Thread in #{board_id}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: Author | Title | Message\t\t#{host}\t#{port}
    i(Use Anonymous if no author name)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExample:\t\t#{host}\t#{port}
    iJohn | Hello World | This is my first post!\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_board_new_thread(input, host, port, ip) do
    # Parse: board_id|author|title|body
    case String.split(input, "|") |> Enum.map(&String.trim/1) do
      [board_id, author, title, body] when title != "" and body != "" ->
        case BulletinBoard.create_thread(board_id, title, body, author, ip) do
          {:ok, thread_id} ->
            format_text_response("""
            === Thread Created ===

            Your thread "#{title}" has been posted.

            Thread ID: #{thread_id}
            """, host, port)

          {:error, :board_not_found} ->
            error_response("Board not found")

          {:error, :title_too_long} ->
            error_response("Title too long (max 100 characters)")

          {:error, :body_too_long} ->
            error_response("Message too long (max 4000 characters)")

          {:error, :empty_content} ->
            error_response("Title and message cannot be empty")
        end

      _ ->
        error_response("Invalid format. Use: BoardID | Author | Title | Message")
    end
  end

  defp board_reply_prompt(_board_id, _thread_id, host, port) do
    """
    iReply to Thread\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: Author | Your reply message\t\t#{host}\t#{port}
    i(Use Anonymous if no author name)\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_board_reply(input, host, port, ip) do
    # Parse: board_id|thread_id|author|body
    case String.split(input, "|") |> Enum.map(&String.trim/1) do
      [board_id, thread_id, author, body] when body != "" ->
        case BulletinBoard.reply(board_id, thread_id, body, author, ip) do
          {:ok, _reply_id} ->
            format_text_response("""
            === Reply Posted ===

            Your reply has been posted successfully.
            """, host, port)

          {:error, :board_not_found} ->
            error_response("Board not found")

          {:error, :thread_not_found} ->
            error_response("Thread not found")

          {:error, :body_too_long} ->
            error_response("Message too long (max 4000 characters)")

          {:error, :empty_content} ->
            error_response("Message cannot be empty")
        end

      _ ->
        error_response("Invalid format. Use: BoardID | ThreadID | Author | Message")
    end
  end

  defp handle_board_recent(host, port) do
    case BulletinBoard.recent(20) do
      {:ok, posts} ->
        post_lines = if posts == [] do
          "iNo posts yet.\t\t#{host}\t#{port}"
        else
          posts
          |> Enum.map(fn p ->
            date = format_date(p.created_at)
            type_label = if p.type == :thread, do: "Thread", else: "Reply"
            title = if p.title, do: p.title, else: String.slice(p.body, 0, 40) <> "..."
            "i[#{type_label}] #{title} - #{p.author} (#{date})\t\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")
        end

        """
        i=== Recent Posts ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{post_lines}
        i\t\t#{host}\t#{port}
        1Back to Boards\t/board\t#{host}\t#{port}
        .
        """
    end
  end

  defp format_date(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        Elixir.Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ ->
        iso_string
    end
  end

  defp format_date(_), do: "unknown"

  # Format as Gopher text response (type 0)
  # Escapes dangerous characters that could break Gopher protocol
  defp format_text_response(text, host, port) do
    lines =
      text
      |> InputSanitizer.escape_gopher()
      |> String.split("\r\n")
      |> Enum.map(&"i#{&1}\t\t#{host}\t#{port}")
      |> Enum.join("\r\n")

    lines <> "\r\n.\r\n"
  end

  # Format lines as Gopher info lines with proper escaping
  defp format_gopher_lines(lines, host, port) do
    lines
    |> Enum.map(fn line ->
      escaped = InputSanitizer.escape_gopher(line)
      "i#{escaped}\t\t#{host}\t#{port}\r\n"
    end)
    |> Enum.join("")
  end

  # Format multi-line text as Gopher info lines (for embedding in menus)
  defp format_text_as_info(text, host, port) do
    text
    |> InputSanitizer.escape_gopher()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)
    |> Enum.join("\r\n")
  end

  # === User Phlog Functions ===

  defp user_phlog_authors(host, port) do
    case UserPhlog.list_authors(limit: 50) do
      {:ok, []} ->
        format_text_response("""
        === Phlog Authors ===

        No user phlogs yet. Create a profile and start writing!
        """, host, port)

      {:ok, authors} ->
        author_lines = authors
          |> Enum.map(fn a ->
            "1~#{a.username} (#{a.count} posts)\t/phlog/user/#{a.username}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Phlog Authors ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iUsers who write phlogs (blogs):\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{author_lines}
        i\t\t#{host}\t#{port}
        1Recent Posts (All Users)\t/phlog/recent\t#{host}\t#{port}
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """
    end
  end

  defp user_phlog_recent(host, port) do
    case UserPhlog.recent_posts(limit: 20) do
      {:ok, []} ->
        format_text_response("""
        === Recent User Posts ===

        No posts yet. Create a profile and start writing!
        """, host, port)

      {:ok, posts} ->
        post_lines = posts
          |> Enum.map(fn p ->
            date = format_date(p.created_at)
            "0[#{date}] #{p.title} (by ~#{p.username})\t/phlog/user/#{p.username_lower}/#{p.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Recent User Posts ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{post_lines}
        i\t\t#{host}\t#{port}
        1View by Author\t/phlog/users\t#{host}\t#{port}
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """
    end
  end

  defp user_phlog_list(username, host, port) do
    case UserPhlog.list_posts(username, limit: 50) do
      {:ok, [], _total} ->
        """
        i=== ~#{username}'s Phlog ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo posts yet.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Write a Post\t/phlog/user/#{username}/write\t#{host}\t#{port}
        1View Profile\t/users/~#{username}\t#{host}\t#{port}
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """

      {:ok, posts, total} ->
        post_lines = posts
          |> Enum.map(fn p ->
            date = format_date(p.created_at)
            "0[#{date}] #{p.title}\t/phlog/user/#{username}/#{p.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== ~#{username}'s Phlog ===\t\t#{host}\t#{port}
        i#{total} posts\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{post_lines}
        i\t\t#{host}\t#{port}
        7Write a Post\t/phlog/user/#{username}/write\t#{host}\t#{port}
        1View Profile\t/users/~#{username}\t#{host}\t#{port}
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """
    end
  end

  defp user_phlog_view(username, post_id, host, port) do
    case UserPhlog.get_post(username, post_id) do
      {:ok, post} ->
        date = format_date(post.created_at)

        body_lines = post.body
          |> String.split("\n")
          |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")

        """
        i=========================================\t\t#{host}\t#{port}
        i   #{post.title}\t\t#{host}\t#{port}
        i   by ~#{post.username}\t\t#{host}\t#{port}
        i   #{date}\t\t#{host}\t#{port}
        i=========================================\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{body_lines}
        i\t\t#{host}\t#{port}
        i---\t\t#{host}\t#{port}
        iViews: #{post.views}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1More posts by ~#{post.username}\t/phlog/user/#{username}\t#{host}\t#{port}
        1View Author Profile\t/users/~#{username}\t#{host}\t#{port}
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Post not found.")
    end
  end

  defp user_phlog_write_prompt(username, host, port) do
    """
    i=== Write a Phlog Post ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPosting as: ~#{username}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter: passphrase|title|body\t\t#{host}\t#{port}
    i(Use | to separate fields)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExample:\t\t#{host}\t#{port}
    imypassword|My First Post|This is my post content.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTitle: max 100 characters\t\t#{host}\t#{port}
    iBody: max 10,000 characters\t\t#{host}\t#{port}
    iRate limit: 1 post per hour\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_user_phlog_write(username, input, host, port, ip) do
    case String.split(input, "|", parts: 3) do
      [passphrase, title, body] ->
        case UserPhlog.create_post(username, String.trim(passphrase), String.trim(title), String.trim(body), ip) do
          {:ok, post} ->
            """
            i=== Post Published! ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iYour post "#{post.title}" has been published.\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            0View Your Post\t/phlog/user/#{username}/#{post.id}\t#{host}\t#{port}
            1Your Phlog\t/phlog/user/#{username}\t#{host}\t#{port}
            1Back to Phlog\t/phlog\t#{host}\t#{port}
            .
            """

          {:error, :invalid_credentials} ->
            error_response("Invalid passphrase.")

          {:error, :rate_limited} ->
            error_response("Rate limited. You can only post once per hour.")

          {:error, :empty_title} ->
            error_response("Title cannot be empty.")

          {:error, :title_too_long} ->
            error_response("Title too long. Maximum 100 characters.")

          {:error, :empty_body} ->
            error_response("Body cannot be empty.")

          {:error, :body_too_long} ->
            error_response("Body too long. Maximum 10,000 characters.")

          {:error, :post_limit_reached} ->
            error_response("You've reached the maximum of 100 posts.")

          {:error, :content_blocked, reason} ->
            error_response("Content blocked: #{reason}")

          {:error, reason} ->
            error_response("Failed to create post: #{sanitize_error(reason)}")
        end

      _ ->
        error_response("Invalid format. Use: passphrase|title|body")
    end
  end

  defp user_phlog_edit_prompt(username, post_id, host, port) do
    case UserPhlog.get_post(username, post_id) do
      {:ok, post} ->
        """
        i=== Edit Post ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iEditing: #{post.title}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iEnter: passphrase|new title|new body\t\t#{host}\t#{port}
        i(Use | to separate fields)\t\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Post not found.")
    end
  end

  defp handle_user_phlog_edit(username, post_id, input, host, port, ip) do
    case String.split(input, "|", parts: 3) do
      [passphrase, title, body] ->
        case UserPhlog.edit_post(username, String.trim(passphrase), post_id, String.trim(title), String.trim(body), ip) do
          {:ok, post} ->
            """
            i=== Post Updated! ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            0View Your Post\t/phlog/user/#{username}/#{post.id}\t#{host}\t#{port}
            1Your Phlog\t/phlog/user/#{username}\t#{host}\t#{port}
            .
            """

          {:error, :invalid_credentials} ->
            error_response("Invalid passphrase.")

          {:error, :not_found} ->
            error_response("Post not found.")

          {:error, :content_blocked, reason} ->
            error_response("Content blocked: #{reason}")

          {:error, reason} ->
            error_response("Failed to update: #{sanitize_error(reason)}")
        end

      _ ->
        error_response("Invalid format. Use: passphrase|title|body")
    end
  end

  defp user_phlog_delete_prompt(username, post_id, host, port) do
    case UserPhlog.get_post(username, post_id) do
      {:ok, post} ->
        """
        i=== Delete Post ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iAre you sure you want to delete:\t\t#{host}\t#{port}
        i"#{post.title}"?\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iThis cannot be undone!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iEnter your passphrase to confirm:\t\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Post not found.")
    end
  end

  defp handle_user_phlog_delete(username, post_id, passphrase, host, port) do
    case UserPhlog.delete_post(username, String.trim(passphrase), post_id) do
      :ok ->
        """
        i=== Post Deleted ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iYour post has been deleted.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Your Phlog\t/phlog/user/#{username}\t#{host}\t#{port}
        1Back to Phlog\t/phlog\t#{host}\t#{port}
        .
        """

      {:error, :invalid_credentials} ->
        error_response("Invalid passphrase.")

      {:error, :not_found} ->
        error_response("Post not found.")

      {:error, reason} ->
        error_response("Failed to delete: #{sanitize_error(reason)}")
    end
  end

  # === Phlog Formatting Functions ===

  defp phlog_format_menu(host, port) do
    """
    i\t\t#{host}\t#{port}
    i    ╔═══════════════════════════════════════════════════════╗\t\t#{host}\t#{port}
    i    ║         PHLOG FORMATTING & CREATIVE TOOLS             ║\t\t#{host}\t#{port}
    i    ╚═══════════════════════════════════════════════════════╝\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i    Transform your phlog posts with AI-powered formatting!\t\t#{host}\t#{port}
    i    Inspired by medieval illuminated manuscripts.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   FEATURES\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i   * Markdown to Gopher conversion\t\t#{host}\t#{port}
    i   * Illuminated drop caps (decorative first letters)\t\t#{host}\t#{port}
    i   * Thematic ASCII art illustrations\t\t#{host}\t#{port}
    i   * Medieval-style borders and ornaments\t\t#{host}\t#{port}
    i   * Auto-link detection (URLs, Gopher, email)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   TOOLS\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Preview Formatted Content\t/phlog/format/preview\t#{host}\t#{port}
    1View Formatting Styles\t/phlog/format/styles\t#{host}\t#{port}
    1Browse Art Gallery\t/phlog/format/art\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   MARKDOWN GUIDE\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i   Headers:    # Title, ## Section, ### Subsection\t\t#{host}\t#{port}
    i   Links:      [text](gopher://host/path)\t\t#{host}\t#{port}
    i   Images:     ![alt](path/to/image.gif)\t\t#{host}\t#{port}
    i   Bold:       **text** or __text__\t\t#{host}\t#{port}
    i   Italic:     *text* or _text_\t\t#{host}\t#{port}
    i   Code:       `inline` or ```block```\t\t#{host}\t#{port}
    i   Lists:      - item or 1. item\t\t#{host}\t#{port}
    i   Quote:      > quoted text\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Phlog\t/phlog\t#{host}\t#{port}
    1Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp phlog_format_preview_prompt(host, port) do
    """
    i=== Preview Formatted Content ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter: title|body\t\t#{host}\t#{port}
    i(Separate title and body with |)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iThe body can include Markdown:\t\t#{host}\t#{port}
    i  # Headers, **bold**, *italic*\t\t#{host}\t#{port}
    i  [links](url), ![images](path)\t\t#{host}\t#{port}
    i  - lists, > quotes, `code`\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExample:\t\t#{host}\t#{port}
    iMy Adventure|Today I went on a **journey** to the forest.\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_phlog_format_preview(input, host, port) do
    case String.split(input, "|", parts: 2) do
      [title, body] when byte_size(title) > 0 and byte_size(body) > 0 ->
        # Format the content
        formatted = PhlogFormatter.format(
          String.trim(title),
          String.trim(body),
          host: host, port: port, style: :medieval
        )

        # Get preview metadata
        preview = PhlogFormatter.preview(title, body, host: host, port: port)

        # Convert to Gopher info lines
        formatted_lines = formatted
          |> String.split("\n")
          |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")

        """
        i\t\t#{host}\t#{port}
        i=== FORMATTED PREVIEW ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTheme detected: #{preview.theme}\t\t#{host}\t#{port}
        iWord count: #{preview.word_count}\t\t#{host}\t#{port}
        iLine count: #{preview.line_count}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i─────────────────────────────────────────────\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted_lines}
        i\t\t#{host}\t#{port}
        i─────────────────────────────────────────────\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTip: Copy this formatting to your phlog post!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try Another Preview\t/phlog/format/preview\t#{host}\t#{port}
        1Formatting Menu\t/phlog/format\t#{host}\t#{port}
        .
        """

      _ ->
        error_response("Format: title|body (separate with |)")
    end
  end

  defp phlog_format_styles(host, port) do
    # Show examples of each style
    example_text = "Hello world"

    minimal_preview = PhlogFormatter.format("Example Post", example_text,
      host: host, port: port, style: :minimal, drop_cap: false, illustrations: false)
      |> String.split("\n")
      |> Enum.take(8)
      |> Enum.map(&("i    #{&1}\t\t#{host}\t#{port}"))
      |> Enum.join("\r\n")

    ornate_preview = PhlogFormatter.format("Example Post", example_text,
      host: host, port: port, style: :ornate, drop_cap: false, illustrations: false)
      |> String.split("\n")
      |> Enum.take(8)
      |> Enum.map(&("i    #{&1}\t\t#{host}\t#{port}"))
      |> Enum.join("\r\n")

    medieval_preview = PhlogFormatter.format("Example Post", example_text,
      host: host, port: port, style: :medieval, drop_cap: true, illustrations: false)
      |> String.split("\n")
      |> Enum.take(12)
      |> Enum.map(&("i    #{&1}\t\t#{host}\t#{port}"))
      |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i    ╔═══════════════════════════════════════════════════════╗\t\t#{host}\t#{port}
    i    ║              FORMATTING STYLES                        ║\t\t#{host}\t#{port}
    i    ╚═══════════════════════════════════════════════════════╝\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   MINIMAL STYLE\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   Clean, simple borders. Good for technical content.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{minimal_preview}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   ORNATE STYLE\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   Decorative boxes and flourishes. Elegant appearance.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{ornate_preview}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   MEDIEVAL STYLE (Default)\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   Illuminated drop caps, ornate borders, thematic art.\t\t#{host}\t#{port}
    i   Inspired by medieval manuscripts.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{medieval_preview}
    i\t\t#{host}\t#{port}
    1Back to Formatting\t/phlog/format\t#{host}\t#{port}
    .
    """
  end

  defp phlog_art_gallery(host, port) do
    themes = PhlogArt.themes()

    theme_lines = themes
      |> Enum.map(fn theme ->
        "1#{theme |> Atom.to_string() |> String.capitalize()}\t/phlog/format/art/#{theme}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i    ╔═══════════════════════════════════════════════════════╗\t\t#{host}\t#{port}
    i    ║              ASCII ART GALLERY                        ║\t\t#{host}\t#{port}
    i    ╚═══════════════════════════════════════════════════════╝\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i    Browse thematic ASCII art for your phlog posts.\t\t#{host}\t#{port}
    i    Art is automatically selected based on your content,\t\t#{host}\t#{port}
    i    or you can choose a specific theme.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   THEMES (#{length(themes)} available)\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{theme_lines}
    i\t\t#{host}\t#{port}
    1Back to Formatting\t/phlog/format\t#{host}\t#{port}
    .
    """
  end

  defp phlog_art_theme(theme_str, host, port) do
    theme = String.to_existing_atom(theme_str)
    arts = PhlogArt.get_all_art(theme)

    art_displays = arts
      |> Enum.with_index(1)
      |> Enum.map(fn {art, idx} ->
        art_lines = art
          |> String.trim()
          |> String.split("\n")
          |> Enum.map(&("i    #{&1}\t\t#{host}\t#{port}"))
          |> Enum.join("\r\n")

        "i--- Option #{idx} ---\t\t#{host}\t#{port}\r\n#{art_lines}"
      end)
      |> Enum.join("\r\ni\t\t#{host}\t#{port}\r\n")

    """
    i\t\t#{host}\t#{port}
    i=== #{String.upcase(theme_str)} Art ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i#{length(arts)} variations available:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{art_displays}
    i\t\t#{host}\t#{port}
    1Back to Gallery\t/phlog/format/art\t#{host}\t#{port}
    1Back to Formatting\t/phlog/format\t#{host}\t#{port}
    .
    """
  rescue
    ArgumentError ->
      error_response("Unknown theme: #{theme_str}")
  end

  # === Color (ANSI) Art Functions ===

  defp phlog_color_art_menu(host, port) do
    """
    i\t\t#{host}\t#{port}
    i    ╔═══════════════════════════════════════════════════════╗\t\t#{host}\t#{port}
    i    ║      \e[31mC\e[33mO\e[32mL\e[36mO\e[34mR\e[35m \e[31mA\e[33mR\e[32mT\e[0m FOR ANSI TERMINALS           ║\t\t#{host}\t#{port}
    i    ╚═══════════════════════════════════════════════════════╝\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i    \e[93mNOTE:\e[0m This section uses ANSI escape codes for color.\t\t#{host}\t#{port}
    i    If you see garbled text like "[31m", your terminal\t\t#{host}\t#{port}
    i    doesn't support ANSI colors. Use the plain art instead.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   FEATURES\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i   * \e[91m1\e[93m6\e[92m-\e[96mc\e[94mo\e[95ml\e[91mo\e[93mr\e[0m ANSI art for supporting terminals\t\t#{host}\t#{port}
    i   * Colorful illuminated drop caps\t\t#{host}\t#{port}
    i   * Rainbow and themed borders\t\t#{host}\t#{port}
    i   * Falls back to plain ASCII if needed\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   BROWSE\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Color Art Gallery\t/phlog/format/color/gallery\t#{host}\t#{port}
    1Color Borders\t/phlog/format/color/borders\t#{host}\t#{port}
    7Preview Color Formatting\t/phlog/format/color/preview\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i   COMPATIBILITY\t\t#{host}\t#{port}
    i════════════════════════════════════════════════════════════\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i   Supported: Most Linux/Mac terminals, PuTTY, xterm\t\t#{host}\t#{port}
    i   Not supported: Some basic Gopher clients\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Plain ASCII Art (No Colors)\t/phlog/format/art\t#{host}\t#{port}
    1Back to Formatting\t/phlog/format\t#{host}\t#{port}
    .
    """
  end

  defp phlog_color_art_gallery(host, port) do
    themes = AnsiArt.themes()

    theme_lines = themes
      |> Enum.map(fn theme ->
        "1#{theme |> Atom.to_string() |> String.capitalize()}\t/phlog/format/color/gallery/#{theme}\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i\t\t#{host}\t#{port}
    i    \e[93m╔═══════════════════════════════════════════════════════╗\e[0m\t\t#{host}\t#{port}
    i    \e[93m║\e[0m       \e[91mC\e[93mO\e[92mL\e[96mO\e[94mR\e[0m ASCII ART GALLERY             \e[93m║\e[0m\t\t#{host}\t#{port}
    i    \e[93m╚═══════════════════════════════════════════════════════╝\e[0m\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i    Browse themed ANSI color art for your phlog posts.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[0m\t\t#{host}\t#{port}
    i   THEMES (#{length(themes)} available)\t\t#{host}\t#{port}
    i\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[31m═\e[33m═\e[32m═\e[36m═\e[34m═\e[35m═\e[0m\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{theme_lines}
    i\t\t#{host}\t#{port}
    1Back to Color Menu\t/phlog/format/color\t#{host}\t#{port}
    1Plain Art (No Colors)\t/phlog/format/art\t#{host}\t#{port}
    .
    """
  end

  defp phlog_color_art_theme(theme_str, host, port) do
    theme = String.to_existing_atom(theme_str)
    arts = AnsiArt.get_all_art(theme)

    art_displays = arts
      |> Enum.with_index(1)
      |> Enum.map(fn {art, idx} ->
        art_lines = art
          |> String.trim()
          |> String.split("\n")
          |> Enum.map(&("i    #{&1}\t\t#{host}\t#{port}"))
          |> Enum.join("\r\n")

        "i\e[93m--- Option #{idx} ---\e[0m\t\t#{host}\t#{port}\r\n#{art_lines}"
      end)
      |> Enum.join("\r\ni\t\t#{host}\t#{port}\r\n")

    """
    i\t\t#{host}\t#{port}
    i\e[93m=== \e[91m#{String.upcase(theme_str)}\e[93m Color Art ===\e[0m\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i#{length(arts)} color variations available:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{art_displays}
    i\t\t#{host}\t#{port}
    1Back to Color Gallery\t/phlog/format/color/gallery\t#{host}\t#{port}
    1Back to Color Menu\t/phlog/format/color\t#{host}\t#{port}
    .
    """
  rescue
    ArgumentError ->
      error_response("Unknown theme: #{theme_str}")
  end

  defp phlog_color_borders(host, port) do
    border_styles = AnsiArt.border_styles()

    border_demos = border_styles
      |> Enum.map(fn style ->
        border = AnsiArt.divider(style, 40)
        "i  #{style |> Atom.to_string() |> String.capitalize()}:\t\t#{host}\t#{port}\r\ni  #{border}\t\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\ni\t\t#{host}\t#{port}\r\n")

    """
    i\t\t#{host}\t#{port}
    i\e[93m╔═══════════════════════════════════════════════════════╗\e[0m\t\t#{host}\t#{port}
    i\e[93m║\e[0m          \e[91mC\e[93mO\e[92mL\e[96mO\e[94mR\e[0m BORDER STYLES               \e[93m║\e[0m\t\t#{host}\t#{port}
    i\e[93m╚═══════════════════════════════════════════════════════╝\e[0m\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i    Available border styles for phlog decoration:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{border_demos}
    i\t\t#{host}\t#{port}
    1Back to Color Menu\t/phlog/format/color\t#{host}\t#{port}
    1Back to Formatting\t/phlog/format\t#{host}\t#{port}
    .
    """
  end

  defp phlog_color_preview_prompt(host, port) do
    """
    i\e[93m=== Preview Color Formatted Content ===\e[0m\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter: title|body\t\t#{host}\t#{port}
    i(Separate title and body with |)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iThis will show your content with \e[91mc\e[93mo\e[92ml\e[96mo\e[94mr\e[0m formatting.\t\t#{host}\t#{port}
    iANSI escape codes will be included for\t\t#{host}\t#{port}
    iterminals that support them.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExample:\t\t#{host}\t#{port}
    iMy Journey|I went on an **adventure** today!\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_phlog_color_preview(input, host, port) do
    case String.split(input, "|", parts: 2) do
      [title, body] when byte_size(title) > 0 and byte_size(body) > 0 ->
        # Format with color enabled
        formatted = PhlogFormatter.format(
          String.trim(title),
          String.trim(body),
          host: host, port: port, style: :medieval, color: true
        )

        preview = PhlogFormatter.preview(title, body, host: host, port: port)

        formatted_lines = formatted
          |> String.split("\n")
          |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")

        """
        i\t\t#{host}\t#{port}
        i\e[93m=== COLOR FORMATTED PREVIEW ===\e[0m\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTheme detected: \e[96m#{preview.theme}\e[0m\t\t#{host}\t#{port}
        iWord count: #{preview.word_count}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[0m\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{formatted_lines}
        i\t\t#{host}\t#{port}
        i\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[31m─\e[33m─\e[32m─\e[36m─\e[34m─\e[35m─\e[0m\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTip: Content uses ANSI color codes!\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try Another Preview\t/phlog/format/color/preview\t#{host}\t#{port}
        1Color Menu\t/phlog/format/color\t#{host}\t#{port}
        1Plain Preview (No Color)\t/phlog/format/preview\t#{host}\t#{port}
        .
        """

      _ ->
        error_response("Format: title|body (separate with |)")
    end
  end

  # Error response
  defp error_response(message) do
    """
    3#{message}\t\terror.host\t1
    .
    """
  end

  # Sanitize internal error reasons for user-facing messages
  # Prevents leaking internal implementation details
  defp sanitize_error(reason) do
    case reason do
      # File/IO errors
      :enoent -> "File not found"
      :eacces -> "Permission denied"
      :eisdir -> "Path is a directory"
      :enotdir -> "Not a directory"
      :enomem -> "Insufficient memory"
      :enospc -> "No space left on device"

      # Network errors
      :timeout -> "Request timed out"
      :closed -> "Connection closed"
      :econnrefused -> "Connection refused"
      :ehostunreach -> "Host unreachable"
      :enetunreach -> "Network unreachable"
      {:connect_failed, _} -> "Connection failed"
      {:send_failed, _} -> "Send failed"
      {:recv_failed, _} -> "Receive failed"

      # Application-specific errors
      :not_found -> "Not found"
      :invalid_input -> "Invalid input"
      :empty_content -> "Content cannot be empty"
      :rate_limited -> "Rate limit exceeded"
      :already_exists -> "Already exists"
      :already_ingested -> "Already processed"
      :path_not_allowed -> "Path not allowed"
      :invalid_host -> "Invalid host"
      :invalid_url -> "Invalid URL"
      :file_not_found -> "File not found"
      :content_blocked -> "Content not allowed"
      {:content_blocked, _} -> "Content not allowed"
      :question_too_long -> "Question too long"
      :option_too_long -> "Option too long"
      :empty_question -> "Question cannot be empty"
      :empty_option -> "Option cannot be empty"
      :title_too_long -> "Title too long"
      :body_too_long -> "Content too long"
      :empty_title -> "Title cannot be empty"
      :empty_body -> "Content cannot be empty"
      :invalid_credentials -> "Invalid credentials"
      :unauthorized -> "Unauthorized"
      :poll_closed -> "Poll has closed"
      :already_voted -> "Already voted"
      :invalid_option -> "Invalid option"
      :recipient_not_found -> "Recipient not found"
      :recipient_inbox_full -> "Recipient inbox full"
      :passphrase_too_short -> "Passphrase too short"
      :invalid_username -> "Invalid username"
      :username_taken -> "Username already taken"
      :post_limit_reached -> "Post limit reached"

      # Tuple errors - extract message if available
      {:error, inner} -> sanitize_error(inner)
      {atom, _detail} when is_atom(atom) -> sanitize_error(atom)

      # Unknown errors - generic message
      _ -> "An error occurred"
    end
  end
end
