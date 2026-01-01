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
  alias PureGopherAi.ConversationStore
  alias PureGopherAi.ModelRegistry
  alias PureGopherAi.Telemetry
  alias PureGopherAi.Phlog
  alias PureGopherAi.Search
  alias PureGopherAi.AsciiArt
  alias PureGopherAi.Admin
  alias PureGopherAi.Rag
  alias PureGopherAi.Summarizer
  alias PureGopherAi.GopherProxy
  alias PureGopherAi.Guestbook
  alias PureGopherAi.CodeAssistant
  alias PureGopherAi.Adventure
  alias PureGopherAi.FeedAggregator
  alias PureGopherAi.Weather
  alias PureGopherAi.Fortune
  alias PureGopherAi.LinkDirectory
  alias PureGopherAi.BulletinBoard
  alias PureGopherAi.HealthCheck
  alias PureGopherAi.InputSanitizer
  alias PureGopherAi.RequestValidator
  alias PureGopherAi.OutputSanitizer
  alias PureGopherAi.Pastebin
  alias PureGopherAi.Polls
  alias PureGopherAi.PhlogComments
  alias PureGopherAi.UserProfiles
  alias PureGopherAi.Calendar
  alias PureGopherAi.UrlShortener
  alias PureGopherAi.Utilities
  alias PureGopherAi.Sitemap
  alias PureGopherAi.Mailbox
  alias PureGopherAi.Trivia

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
        Logger.info("#{network_label} Gopher request: #{inspect(selector)} from #{format_ip(client_ip)}")

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
        Logger.warning("Rate limited: #{format_ip(client_ip)}, retry after #{retry_after}ms")
        # Record violation for abuse detection (may trigger auto-ban)
        RateLimiter.record_violation(client_ip)
        response = rate_limit_response(retry_after)
        ThousandIsland.Socket.send(socket, response)

      {:error, :banned} ->
        Logger.warning("Banned IP attempted access: #{format_ip(client_ip)}")
        response = banned_response()
        ThousandIsland.Socket.send(socket, response)

      {:error, :blocklisted} ->
        Logger.warning("Blocklisted IP attempted access: #{format_ip(client_ip)}")
        response = blocklisted_response()
        ThousandIsland.Socket.send(socket, response)
    end

    {:close, state}
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip), do: inspect(ip)

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

  # Get appropriate host/port based on network type
  defp get_host_port(:tor) do
    onion = Application.get_env(:pure_gopher_ai, :onion_address)

    if onion do
      {onion, 70}
    else
      {"[onion-address]", 70}
    end
  end

  defp get_host_port(:clearnet) do
    host = Application.get_env(:pure_gopher_ai, :clearnet_host, "localhost")
    port = Application.get_env(:pure_gopher_ai, :clearnet_port, 7070)
    {host, port}
  end

  # Route selector to appropriate handler (with socket for streaming)
  defp route_selector("", host, port, network, _ip, _socket), do: root_menu(host, port, network)
  defp route_selector("/", host, port, network, _ip, _socket), do: root_menu(host, port, network)

  # AI queries (stateless) - with streaming support
  defp route_selector("/ask\t" <> query, host, port, _network, _ip, socket),
    do: handle_ask(query, host, port, socket)

  defp route_selector("/ask " <> query, host, port, _network, _ip, socket),
    do: handle_ask(query, host, port, socket)

  defp route_selector("/ask", host, port, _network, _ip, _socket),
    do: ask_prompt(host, port)

  # Chat (with conversation memory) - with streaming support
  defp route_selector("/chat\t" <> query, host, port, _network, client_ip, socket),
    do: handle_chat(query, host, port, client_ip, socket)

  defp route_selector("/chat " <> query, host, port, _network, client_ip, socket),
    do: handle_chat(query, host, port, client_ip, socket)

  defp route_selector("/chat", host, port, _network, _ip, _socket),
    do: chat_prompt(host, port)

  # Clear conversation
  defp route_selector("/clear", host, port, _network, client_ip, _socket),
    do: handle_clear(host, port, client_ip)

  # List available models
  defp route_selector("/models", host, port, _network, _ip, _socket),
    do: models_page(host, port)

  # List available personas
  defp route_selector("/personas", host, port, _network, _ip, _socket),
    do: personas_page(host, port)

  # Persona-specific queries (e.g., /ask-pirate, /ask-coder)
  defp route_selector("/persona-" <> rest, host, port, _network, _ip, socket) do
    case parse_model_query(rest) do
      {persona_id, ""} -> persona_ask_prompt(persona_id, host, port)
      {persona_id, query} -> handle_persona_ask(persona_id, query, host, port, socket)
    end
  end

  # Persona-specific chat
  defp route_selector("/chat-persona-" <> rest, host, port, _network, client_ip, socket) do
    case parse_model_query(rest) do
      {persona_id, ""} -> persona_chat_prompt(persona_id, host, port)
      {persona_id, query} -> handle_persona_chat(persona_id, query, host, port, client_ip, socket)
    end
  end

  # Model-specific queries (e.g., /ask-gpt2, /ask-gpt2-medium)
  defp route_selector("/ask-" <> rest, host, port, _network, _ip, socket) do
    case parse_model_query(rest) do
      {model_id, ""} -> model_ask_prompt(model_id, host, port)
      {model_id, query} -> handle_model_ask(model_id, query, host, port, socket)
    end
  end

  # Model-specific chat (e.g., /chat-gpt2)
  defp route_selector("/chat-" <> rest, host, port, _network, client_ip, socket) do
    case parse_model_query(rest) do
      {model_id, ""} -> model_chat_prompt(model_id, host, port)
      {model_id, query} -> handle_model_chat(model_id, query, host, port, client_ip, socket)
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

  # Pastebin routes
  defp route_selector("/paste", host, port, _network, _ip, _socket),
    do: paste_menu(host, port)

  defp route_selector("/paste/new", host, port, _network, _ip, _socket),
    do: paste_new_prompt(host, port)

  defp route_selector("/paste/new\t" <> content, host, port, _network, ip, _socket),
    do: handle_paste_create(content, ip, host, port)

  defp route_selector("/paste/new " <> content, host, port, _network, ip, _socket),
    do: handle_paste_create(content, ip, host, port)

  defp route_selector("/paste/recent", host, port, _network, _ip, _socket),
    do: paste_recent(host, port)

  defp route_selector("/paste/raw/" <> id, _host, _port, _network, _ip, _socket),
    do: paste_raw(id)

  defp route_selector("/paste/" <> id, host, port, _network, _ip, _socket),
    do: paste_view(id, host, port)

  # Polls routes
  defp route_selector("/polls", host, port, _network, _ip, _socket),
    do: polls_menu(host, port)

  defp route_selector("/polls/new", host, port, _network, _ip, _socket),
    do: polls_new_prompt(host, port)

  defp route_selector("/polls/new\t" <> input, host, port, _network, ip, _socket),
    do: handle_polls_create(input, ip, host, port)

  defp route_selector("/polls/new " <> input, host, port, _network, ip, _socket),
    do: handle_polls_create(input, ip, host, port)

  defp route_selector("/polls/active", host, port, _network, _ip, _socket),
    do: polls_active(host, port)

  defp route_selector("/polls/closed", host, port, _network, _ip, _socket),
    do: polls_closed(host, port)

  defp route_selector("/polls/vote/" <> rest, host, port, _network, ip, _socket),
    do: handle_polls_vote(rest, ip, host, port)

  defp route_selector("/polls/" <> id, host, port, _network, ip, _socket),
    do: polls_view(id, ip, host, port)

  # User Profiles
  defp route_selector("/users", host, port, _network, _ip, _socket),
    do: users_menu(host, port)

  defp route_selector("/users/create", host, port, _network, _ip, _socket),
    do: users_create_prompt(host, port)

  defp route_selector("/users/create\t" <> input, host, port, _network, ip, _socket),
    do: handle_users_create(input, ip, host, port)

  defp route_selector("/users/create " <> input, host, port, _network, ip, _socket),
    do: handle_users_create(input, ip, host, port)

  defp route_selector("/users/search", host, port, _network, _ip, _socket),
    do: users_search_prompt(host, port)

  defp route_selector("/users/search\t" <> query, host, port, _network, _ip, _socket),
    do: handle_users_search(query, host, port)

  defp route_selector("/users/search " <> query, host, port, _network, _ip, _socket),
    do: handle_users_search(query, host, port)

  defp route_selector("/users/list", host, port, _network, _ip, _socket),
    do: users_list(host, port, 1)

  defp route_selector("/users/list/page/" <> page_str, host, port, _network, _ip, _socket) do
    page = case Integer.parse(page_str) do
      {p, ""} when p > 0 -> p
      _ -> 1
    end
    users_list(host, port, page)
  end

  defp route_selector("/users/~" <> username, host, port, _network, _ip, _socket),
    do: users_view(username, host, port)

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
    do: mail_inbox(username, host, port)

  defp route_selector("/mail/sent/" <> username, host, port, _network, _ip, _socket),
    do: mail_sent(username, host, port)

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

  # Search (Type 7)
  defp route_selector("/search", host, port, _network, _ip, _socket),
    do: search_prompt(host, port)

  defp route_selector("/search\t" <> query, host, port, _network, _ip, _socket),
    do: handle_search(query, host, port)

  defp route_selector("/search " <> query, host, port, _network, _ip, _socket),
    do: handle_search(query, host, port)

  # ASCII Art
  defp route_selector("/art", host, port, _network, _ip, _socket),
    do: art_menu(host, port)

  defp route_selector("/art/text", host, port, _network, _ip, _socket),
    do: art_text_prompt(host, port)

  defp route_selector("/art/text\t" <> text, host, port, _network, _ip, _socket),
    do: handle_art_text(text, host, port, :block)

  defp route_selector("/art/text " <> text, host, port, _network, _ip, _socket),
    do: handle_art_text(text, host, port, :block)

  defp route_selector("/art/small", host, port, _network, _ip, _socket),
    do: art_small_prompt(host, port)

  defp route_selector("/art/small\t" <> text, host, port, _network, _ip, _socket),
    do: handle_art_text(text, host, port, :small)

  defp route_selector("/art/small " <> text, host, port, _network, _ip, _socket),
    do: handle_art_text(text, host, port, :small)

  defp route_selector("/art/banner", host, port, _network, _ip, _socket),
    do: art_banner_prompt(host, port)

  defp route_selector("/art/banner\t" <> text, host, port, _network, _ip, _socket),
    do: handle_art_banner(text, host, port)

  defp route_selector("/art/banner " <> text, host, port, _network, _ip, _socket),
    do: handle_art_banner(text, host, port)

  # RAG (Document Query) routes
  defp route_selector("/docs", host, port, _network, _ip, _socket),
    do: docs_menu(host, port)

  defp route_selector("/docs/", host, port, _network, _ip, _socket),
    do: docs_menu(host, port)

  defp route_selector("/docs/list", host, port, _network, _ip, _socket),
    do: docs_list(host, port)

  defp route_selector("/docs/stats", host, port, _network, _ip, _socket),
    do: docs_stats(host, port)

  defp route_selector("/docs/ask", host, port, _network, _ip, _socket),
    do: docs_ask_prompt(host, port)

  defp route_selector("/docs/ask\t" <> query, host, port, _network, _ip, socket),
    do: handle_docs_ask(query, host, port, socket)

  defp route_selector("/docs/ask " <> query, host, port, _network, _ip, socket),
    do: handle_docs_ask(query, host, port, socket)

  defp route_selector("/docs/search", host, port, _network, _ip, _socket),
    do: docs_search_prompt(host, port)

  defp route_selector("/docs/search\t" <> query, host, port, _network, _ip, _socket),
    do: handle_docs_search(query, host, port)

  defp route_selector("/docs/search " <> query, host, port, _network, _ip, _socket),
    do: handle_docs_search(query, host, port)

  defp route_selector("/docs/view/" <> doc_id, host, port, _network, _ip, _socket),
    do: docs_view(doc_id, host, port)

  # === AI Services: Summarization ===

  # Phlog summarization
  defp route_selector("/summary/phlog/" <> path, host, port, _network, _ip, socket),
    do: handle_phlog_summary(path, host, port, socket)

  # Document summarization
  defp route_selector("/summary/doc/" <> doc_id, host, port, _network, _ip, socket),
    do: handle_doc_summary(doc_id, host, port, socket)

  # === AI Services: Translation ===

  # Translation menu
  defp route_selector("/translate", host, port, _network, _ip, _socket),
    do: translate_menu(host, port)

  # Translate phlog: /translate/<lang>/phlog/<path>
  defp route_selector("/translate/" <> rest, host, port, _network, _ip, socket) do
    handle_translate_route(rest, host, port, socket)
  end

  # === AI Services: Dynamic Content ===

  # Daily digest
  defp route_selector("/digest", host, port, _network, _ip, socket),
    do: handle_digest(host, port, socket)

  # Topic discovery
  defp route_selector("/topics", host, port, _network, _ip, socket),
    do: handle_topics(host, port, socket)

  # Content discovery/recommendations
  defp route_selector("/discover", host, port, _network, _ip, _socket),
    do: discover_prompt(host, port)

  defp route_selector("/discover\t" <> interest, host, port, _network, _ip, socket),
    do: handle_discover(interest, host, port, socket)

  defp route_selector("/discover " <> interest, host, port, _network, _ip, socket),
    do: handle_discover(interest, host, port, socket)

  # Explain terms
  defp route_selector("/explain", host, port, _network, _ip, _socket),
    do: explain_prompt(host, port)

  defp route_selector("/explain\t" <> term, host, port, _network, _ip, socket),
    do: handle_explain(term, host, port, socket)

  defp route_selector("/explain " <> term, host, port, _network, _ip, socket),
    do: handle_explain(term, host, port, socket)

  # === Gopher Proxy ===

  # Fetch external gopher content
  defp route_selector("/fetch", host, port, _network, _ip, _socket),
    do: fetch_prompt(host, port)

  defp route_selector("/fetch\t" <> url, host, port, _network, _ip, _socket),
    do: handle_fetch(url, host, port)

  defp route_selector("/fetch " <> url, host, port, _network, _ip, _socket),
    do: handle_fetch(url, host, port)

  # Fetch and summarize
  defp route_selector("/fetch-summary\t" <> url, host, port, _network, _ip, socket),
    do: handle_fetch_summary(url, host, port, socket)

  defp route_selector("/fetch-summary " <> url, host, port, _network, _ip, socket),
    do: handle_fetch_summary(url, host, port, socket)

  # === Guestbook ===

  defp route_selector("/guestbook", host, port, _network, _ip, _socket),
    do: guestbook_page(host, port, 1)

  defp route_selector("/guestbook/page/" <> page_str, host, port, _network, _ip, _socket) do
    page = parse_int(page_str, 1)
    guestbook_page(host, port, page)
  end

  defp route_selector("/guestbook/sign", host, port, _network, _ip, _socket),
    do: guestbook_sign_prompt(host, port)

  defp route_selector("/guestbook/sign\t" <> input, host, port, _network, ip, _socket),
    do: handle_guestbook_sign(input, host, port, ip)

  defp route_selector("/guestbook/sign " <> input, host, port, _network, ip, _socket),
    do: handle_guestbook_sign(input, host, port, ip)

  # === Code Assistant ===

  defp route_selector("/code", host, port, _network, _ip, _socket),
    do: code_menu(host, port)

  defp route_selector("/code/languages", host, port, _network, _ip, _socket),
    do: code_languages(host, port)

  defp route_selector("/code/generate", host, port, _network, _ip, _socket),
    do: code_generate_prompt(host, port)

  defp route_selector("/code/generate\t" <> input, host, port, _network, _ip, socket),
    do: handle_code_generate(input, host, port, socket)

  defp route_selector("/code/generate " <> input, host, port, _network, _ip, socket),
    do: handle_code_generate(input, host, port, socket)

  defp route_selector("/code/explain", host, port, _network, _ip, _socket),
    do: code_explain_prompt(host, port)

  defp route_selector("/code/explain\t" <> input, host, port, _network, _ip, socket),
    do: handle_code_explain(input, host, port, socket)

  defp route_selector("/code/explain " <> input, host, port, _network, _ip, socket),
    do: handle_code_explain(input, host, port, socket)

  defp route_selector("/code/review", host, port, _network, _ip, _socket),
    do: code_review_prompt(host, port)

  defp route_selector("/code/review\t" <> input, host, port, _network, _ip, socket),
    do: handle_code_review(input, host, port, socket)

  defp route_selector("/code/review " <> input, host, port, _network, _ip, socket),
    do: handle_code_review(input, host, port, socket)

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

  defp route_selector("/board/" <> rest, host, port, _network, ip, _socket) do
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

  # Admin routes (token-authenticated)
  defp route_selector("/admin/" <> rest, host, port, _network, _ip, _socket) do
    handle_admin(rest, host, port)
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
    #{files_section}i\t\t#{host}\t#{port}
    i=== Server ===\t\t#{host}\t#{port}
    0About this server\t/about\t#{host}\t#{port}
    0Server statistics\t/stats\t#{host}\t#{port}
    0Health check\t/health\t#{host}\t#{port}
    1Full Sitemap\t/sitemap\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTip: /summary/phlog/<path> for TL;DR summaries\t\t#{host}\t#{port}
    .
    """
  end

  # Prompt for AI query (Type 7 search)
  defp ask_prompt(host, port) do
    """
    iAsk AI a Question\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your question below:\t\t#{host}\t#{port}
    .
    """
  end

  # Models listing page
  defp models_page(host, port) do
    models = ModelRegistry.list_models()
    default_model = ModelRegistry.default_model()

    model_lines =
      models
      |> Enum.map(fn {id, info} ->
        status = if info.loaded, do: "[Loaded]", else: "[Not loaded]"
        default = if id == default_model, do: " (default)", else: ""

        """
        i\t\t#{host}\t#{port}
        i#{info.name}#{default}\t\t#{host}\t#{port}
        i  #{info.description}\t\t#{host}\t#{port}
        i  Status: #{status}\t\t#{host}\t#{port}
        7Ask #{info.name}\t/ask-#{id}\t#{host}\t#{port}
        7Chat with #{info.name}\t/chat-#{id}\t#{host}\t#{port}
        """
      end)
      |> Enum.join("")

    """
    i=== Available AI Models ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iModels are loaded on first use (lazy loading)\t\t#{host}\t#{port}
    #{model_lines}i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  # Parse model ID and query from selector like "gpt2\tquery" or "gpt2 query"
  defp parse_model_query(rest) do
    # Try tab separator first (standard Gopher)
    case String.split(rest, "\t", parts: 2) do
      [model_with_query] ->
        # Try space separator
        case String.split(model_with_query, " ", parts: 2) do
          [model_id, query] -> {model_id, query}
          [model_id] -> {model_id, ""}
        end

      [model_id, query] ->
        {model_id, query}
    end
  end

  # Model-specific ask prompt
  defp model_ask_prompt(model_id, host, port) do
    case ModelRegistry.get_model(model_id) do
      nil ->
        error_response("Unknown model: #{model_id}")

      info ->
        """
        iAsk #{info.name}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{info.description}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iEnter your question below:\t\t#{host}\t#{port}
        .
        """
    end
  end

  # Model-specific chat prompt
  defp model_chat_prompt(model_id, host, port) do
    case ModelRegistry.get_model(model_id) do
      nil ->
        error_response("Unknown model: #{model_id}")

      info ->
        """
        iChat with #{info.name}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{info.description}\t\t#{host}\t#{port}
        iYour conversation history is preserved.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iEnter your message below:\t\t#{host}\t#{port}
        .
        """
    end
  end

  # Handle model-specific ask query
  defp handle_model_ask(model_id, query, host, port, socket) when byte_size(query) > 0 do
    if ModelRegistry.exists?(model_id) do
      Logger.info("AI Query (#{model_id}): #{query}")
      start_time = System.monotonic_time(:millisecond)

      if socket && PureGopherAi.AiEngine.streaming_enabled?() do
        stream_model_response(socket, model_id, query, nil, host, port, start_time)
      else
        response = ModelRegistry.generate(model_id, query)
        elapsed = System.monotonic_time(:millisecond) - start_time
        Logger.info("AI Response (#{model_id}) generated in #{elapsed}ms")

        format_text_response(
          """
          Query: #{query}
          Model: #{model_id}

          Response:
          #{response}

          ---
          Generated in #{elapsed}ms
          """,
          host,
          port
        )
      end
    else
      error_response("Unknown model: #{model_id}")
    end
  end

  defp handle_model_ask(model_id, _query, _host, _port, _socket) do
    if ModelRegistry.exists?(model_id) do
      error_response("Please provide a query after /ask-#{model_id}")
    else
      error_response("Unknown model: #{model_id}")
    end
  end

  # Handle model-specific chat query
  defp handle_model_chat(model_id, query, host, port, client_ip, socket) when byte_size(query) > 0 do
    if ModelRegistry.exists?(model_id) do
      session_id = ConversationStore.get_session_id(client_ip)
      Logger.info("Chat query (#{model_id}) from session #{session_id}: #{query}")

      context = ConversationStore.get_context(session_id)
      ConversationStore.add_message(session_id, :user, query)

      start_time = System.monotonic_time(:millisecond)

      if socket && PureGopherAi.AiEngine.streaming_enabled?() do
        stream_model_chat_response(socket, model_id, query, context, session_id, host, port, start_time)
      else
        response = ModelRegistry.generate(model_id, query, context)
        elapsed = System.monotonic_time(:millisecond) - start_time

        ConversationStore.add_message(session_id, :assistant, response)
        history = ConversationStore.get_history(session_id)
        history_count = length(history)

        Logger.info("Chat response (#{model_id}) generated in #{elapsed}ms, history: #{history_count} messages")

        format_text_response(
          """
          You: #{query}
          Model: #{model_id}

          AI: #{response}

          ---
          Session: #{session_id} | Messages: #{history_count}
          Generated in #{elapsed}ms
          """,
          host,
          port
        )
      end
    else
      error_response("Unknown model: #{model_id}")
    end
  end

  defp handle_model_chat(model_id, _query, _host, _port, _ip, _socket) do
    if ModelRegistry.exists?(model_id) do
      error_response("Please provide a message after /chat-#{model_id}")
    else
      error_response("Unknown model: #{model_id}")
    end
  end

  # Stream model-specific response
  defp stream_model_response(socket, model_id, query, _context, host, port, start_time) do
    header = format_gopher_lines(["Query: #{query}", "Model: #{model_id}", "", "Response:"], host, port)
    ThousandIsland.Socket.send(socket, header)

    _response = ModelRegistry.generate_stream(model_id, query, nil, fn chunk ->
      if String.length(chunk) > 0 do
        lines = String.split(chunk, "\n", trim: false)
        formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
        ThousandIsland.Socket.send(socket, Enum.join(formatted))
      end
    end)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("AI Response (#{model_id}) streamed in #{elapsed}ms")

    footer = format_gopher_lines(["", "---", "Generated in #{elapsed}ms (streamed)"], host, port)
    ThousandIsland.Socket.send(socket, footer <> ".\r\n")

    :streamed
  end

  # Stream model-specific chat response
  defp stream_model_chat_response(socket, model_id, query, context, session_id, host, port, start_time) do
    header = format_gopher_lines(["You: #{query}", "Model: #{model_id}", "", "AI:"], host, port)
    ThousandIsland.Socket.send(socket, header)

    {:ok, response_agent} = Agent.start_link(fn -> [] end)

    _response = ModelRegistry.generate_stream(model_id, query, context, fn chunk ->
      Agent.update(response_agent, fn chunks -> [chunk | chunks] end)
      if String.length(chunk) > 0 do
        lines = String.split(chunk, "\n", trim: false)
        formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
        ThousandIsland.Socket.send(socket, Enum.join(formatted))
      end
    end)

    full_response =
      response_agent
      |> Agent.get(& &1)
      |> Enum.reverse()
      |> Enum.join("")

    Agent.stop(response_agent)

    ConversationStore.add_message(session_id, :assistant, full_response)
    history = ConversationStore.get_history(session_id)
    history_count = length(history)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("Chat response (#{model_id}) streamed in #{elapsed}ms, history: #{history_count} messages")

    footer = format_gopher_lines([
      "",
      "---",
      "Session: #{session_id} | Messages: #{history_count}",
      "Generated in #{elapsed}ms (streamed)"
    ], host, port)
    ThousandIsland.Socket.send(socket, footer <> ".\r\n")

    :streamed
  end

  # === Persona Functions ===

  # Personas listing page
  defp personas_page(host, port) do
    personas = PureGopherAi.AiEngine.list_personas()

    persona_lines =
      personas
      |> Enum.map(fn {id, info} ->
        """
        i\t\t#{host}\t#{port}
        i#{info.name}\t\t#{host}\t#{port}
        i  "#{String.slice(info.prompt, 0..60)}..."\t\t#{host}\t#{port}
        7Ask as #{info.name}\t/persona-#{id}\t#{host}\t#{port}
        7Chat as #{info.name}\t/chat-persona-#{id}\t#{host}\t#{port}
        """
      end)
      |> Enum.join("")

    """
    i=== Available AI Personas ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPersonas modify AI behavior with system prompts\t\t#{host}\t#{port}
    #{persona_lines}i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  # Persona ask prompt
  defp persona_ask_prompt(persona_id, host, port) do
    case PureGopherAi.AiEngine.get_persona(persona_id) do
      nil ->
        error_response("Unknown persona: #{persona_id}")

      info ->
        """
        iAsk #{info.name}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i"#{info.prompt}"\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iEnter your question below:\t\t#{host}\t#{port}
        .
        """
    end
  end

  # Persona chat prompt
  defp persona_chat_prompt(persona_id, host, port) do
    case PureGopherAi.AiEngine.get_persona(persona_id) do
      nil ->
        error_response("Unknown persona: #{persona_id}")

      info ->
        """
        iChat with #{info.name}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i"#{info.prompt}"\t\t#{host}\t#{port}
        iYour conversation history is preserved.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iEnter your message below:\t\t#{host}\t#{port}
        .
        """
    end
  end

  # Handle persona-specific ask
  defp handle_persona_ask(persona_id, query, host, port, socket) when byte_size(query) > 0 do
    if PureGopherAi.AiEngine.persona_exists?(persona_id) do
      Logger.info("AI Query (persona: #{persona_id}): #{query}")
      start_time = System.monotonic_time(:millisecond)

      if socket && PureGopherAi.AiEngine.streaming_enabled?() do
        stream_persona_response(socket, persona_id, query, nil, host, port, start_time)
      else
        case PureGopherAi.AiEngine.generate_with_persona(persona_id, query) do
          {:ok, response} ->
            elapsed = System.monotonic_time(:millisecond) - start_time
            Logger.info("AI Response (persona: #{persona_id}) generated in #{elapsed}ms")

            format_text_response(
              """
              Query: #{query}
              Persona: #{persona_id}

              Response:
              #{response}

              ---
              Generated in #{elapsed}ms
              """,
              host,
              port
            )

          {:error, _} ->
            error_response("Unknown persona: #{persona_id}")
        end
      end
    else
      error_response("Unknown persona: #{persona_id}")
    end
  end

  defp handle_persona_ask(persona_id, _query, _host, _port, _socket) do
    if PureGopherAi.AiEngine.persona_exists?(persona_id) do
      error_response("Please provide a query after /persona-#{persona_id}")
    else
      error_response("Unknown persona: #{persona_id}")
    end
  end

  # Handle persona-specific chat
  defp handle_persona_chat(persona_id, query, host, port, client_ip, socket) when byte_size(query) > 0 do
    if PureGopherAi.AiEngine.persona_exists?(persona_id) do
      session_id = ConversationStore.get_session_id(client_ip)
      Logger.info("Chat query (persona: #{persona_id}) from session #{session_id}: #{query}")

      context = ConversationStore.get_context(session_id)
      ConversationStore.add_message(session_id, :user, query)

      start_time = System.monotonic_time(:millisecond)

      if socket && PureGopherAi.AiEngine.streaming_enabled?() do
        stream_persona_chat_response(socket, persona_id, query, context, session_id, host, port, start_time)
      else
        case PureGopherAi.AiEngine.generate_with_persona(persona_id, query, context) do
          {:ok, response} ->
            elapsed = System.monotonic_time(:millisecond) - start_time

            ConversationStore.add_message(session_id, :assistant, response)
            history = ConversationStore.get_history(session_id)
            history_count = length(history)

            Logger.info("Chat response (persona: #{persona_id}) generated in #{elapsed}ms, history: #{history_count} messages")

            format_text_response(
              """
              You: #{query}
              Persona: #{persona_id}

              AI: #{response}

              ---
              Session: #{session_id} | Messages: #{history_count}
              Generated in #{elapsed}ms
              """,
              host,
              port
            )

          {:error, _} ->
            error_response("Unknown persona: #{persona_id}")
        end
      end
    else
      error_response("Unknown persona: #{persona_id}")
    end
  end

  defp handle_persona_chat(persona_id, _query, _host, _port, _ip, _socket) do
    if PureGopherAi.AiEngine.persona_exists?(persona_id) do
      error_response("Please provide a message after /chat-persona-#{persona_id}")
    else
      error_response("Unknown persona: #{persona_id}")
    end
  end

  # Stream persona response
  defp stream_persona_response(socket, persona_id, query, _context, host, port, start_time) do
    header = format_gopher_lines(["Query: #{query}", "Persona: #{persona_id}", "", "Response:"], host, port)
    ThousandIsland.Socket.send(socket, header)

    case PureGopherAi.AiEngine.generate_stream_with_persona(persona_id, query, nil, fn chunk ->
           if String.length(chunk) > 0 do
             lines = String.split(chunk, "\n", trim: false)
             formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
             ThousandIsland.Socket.send(socket, Enum.join(formatted))
           end
         end) do
      {:ok, _response} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        Logger.info("AI Response (persona: #{persona_id}) streamed in #{elapsed}ms")

        footer = format_gopher_lines(["", "---", "Generated in #{elapsed}ms (streamed)"], host, port)
        ThousandIsland.Socket.send(socket, footer <> ".\r\n")

      {:error, _} ->
        ThousandIsland.Socket.send(socket, "i[Error: Unknown persona]\t\t#{host}\t#{port}\r\n.\r\n")
    end

    :streamed
  end

  # Stream persona chat response
  defp stream_persona_chat_response(socket, persona_id, query, context, session_id, host, port, start_time) do
    header = format_gopher_lines(["You: #{query}", "Persona: #{persona_id}", "", "AI:"], host, port)
    ThousandIsland.Socket.send(socket, header)

    {:ok, response_agent} = Agent.start_link(fn -> [] end)

    result = PureGopherAi.AiEngine.generate_stream_with_persona(persona_id, query, context, fn chunk ->
      Agent.update(response_agent, fn chunks -> [chunk | chunks] end)
      if String.length(chunk) > 0 do
        lines = String.split(chunk, "\n", trim: false)
        formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
        ThousandIsland.Socket.send(socket, Enum.join(formatted))
      end
    end)

    case result do
      {:ok, _} ->
        full_response =
          response_agent
          |> Agent.get(& &1)
          |> Enum.reverse()
          |> Enum.join("")

        ConversationStore.add_message(session_id, :assistant, full_response)

      {:error, _} ->
        :ok
    end

    Agent.stop(response_agent)

    history = ConversationStore.get_history(session_id)
    history_count = length(history)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("Chat response (persona: #{persona_id}) streamed in #{elapsed}ms, history: #{history_count} messages")

    footer = format_gopher_lines([
      "",
      "---",
      "Session: #{session_id} | Messages: #{history_count}",
      "Generated in #{elapsed}ms (streamed)"
    ], host, port)
    ThousandIsland.Socket.send(socket, footer <> ".\r\n")

    :streamed
  end

  # Handle AI query with streaming support and security checks
  defp handle_ask(query, host, port, socket) when byte_size(query) > 0 do
    # Validate and sanitize the query
    case RequestValidator.validate_query(query) do
      {:ok, _} ->
        case InputSanitizer.sanitize_prompt(query) do
          {:ok, sanitized_query} ->
            Logger.info("AI Query: #{sanitized_query}")
            start_time = System.monotonic_time(:millisecond)

            if socket && PureGopherAi.AiEngine.streaming_enabled?() do
              # Stream response to socket
              stream_ai_response(socket, sanitized_query, nil, host, port, start_time)
            else
              # Non-streaming fallback
              response = PureGopherAi.AiEngine.generate(sanitized_query)
              # Sanitize output for potential sensitive data
              safe_response = OutputSanitizer.sanitize(response)
              elapsed = System.monotonic_time(:millisecond) - start_time
              Logger.info("AI Response generated in #{elapsed}ms")

              format_text_response(
                """
                Query: #{sanitized_query}

                Response:
                #{safe_response}

                ---
                Generated in #{elapsed}ms using GPU acceleration
                """,
                host,
                port
              )
            end

          {:blocked, reason} ->
            Logger.warning("Blocked AI query (injection attempt): #{String.slice(query, 0..50)}")
            format_text_response(
              """
              Query Blocked

              Your query was rejected for security reasons.
              Reason: #{reason}

              Please rephrase your question without special instructions.
              """,
              host,
              port
            )
        end

      {:error, reason} ->
        Logger.warning("Invalid AI query: #{reason}")
        error_response("Invalid query: #{reason}")
    end
  end

  defp handle_ask(_, _host, _port, _socket), do: error_response("Please provide a query after /ask")

  # Prompt for chat (Type 7 search)
  defp chat_prompt(host, port) do
    """
    iChat with AI (Conversation Memory)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iYour conversation history is preserved.\t\t#{host}\t#{port}
    iEnter your message below:\t\t#{host}\t#{port}
    .
    """
  end

  # Handle chat query with conversation memory, streaming support, and security checks
  defp handle_chat(query, host, port, client_ip, socket) when byte_size(query) > 0 do
    # Validate and sanitize the query
    case RequestValidator.validate_query(query) do
      {:ok, _} ->
        case InputSanitizer.sanitize_prompt(query) do
          {:ok, sanitized_query} ->
            session_id = ConversationStore.get_session_id(client_ip)
            Logger.info("Chat query from session #{session_id}: #{sanitized_query}")

            # Get existing conversation context
            context = ConversationStore.get_context(session_id)

            # Add user message to history
            ConversationStore.add_message(session_id, :user, sanitized_query)

            start_time = System.monotonic_time(:millisecond)

            if socket && PureGopherAi.AiEngine.streaming_enabled?() do
              # Stream response to socket with chat context
              stream_chat_response(socket, sanitized_query, context, session_id, host, port, start_time)
            else
              # Non-streaming fallback
              response = PureGopherAi.AiEngine.generate(sanitized_query, context)
              # Sanitize output for potential sensitive data
              safe_response = OutputSanitizer.sanitize(response)
              elapsed = System.monotonic_time(:millisecond) - start_time

              # Add assistant response to history
              ConversationStore.add_message(session_id, :assistant, safe_response)

              # Get updated history for display
              history = ConversationStore.get_history(session_id)
              history_count = length(history)

              Logger.info("Chat response generated in #{elapsed}ms, history: #{history_count} messages")

              format_text_response(
                """
                You: #{sanitized_query}

                AI: #{safe_response}

                ---
                Session: #{session_id} | Messages: #{history_count}
                Generated in #{elapsed}ms
                """,
                host,
                port
              )
            end

          {:blocked, reason} ->
            Logger.warning("Blocked chat message (injection attempt): #{String.slice(query, 0..50)}")
            format_text_response(
              """
              Message Blocked

              Your message was rejected for security reasons.
              Reason: #{reason}

              Please rephrase your message without special instructions.
              """,
              host,
              port
            )
        end

      {:error, reason} ->
        Logger.warning("Invalid chat query: #{reason}")
        error_response("Invalid message: #{reason}")
    end
  end

  defp handle_chat(_, _host, _port, _ip, _socket), do: error_response("Please provide a message after /chat")

  # Handle conversation clear
  defp handle_clear(host, port, client_ip) do
    session_id = ConversationStore.get_session_id(client_ip)
    ConversationStore.clear(session_id)
    Logger.info("Conversation cleared for session #{session_id}")

    format_text_response(
      """
      Conversation Cleared

      Your chat history has been reset.
      Start a new conversation with /chat.

      Session: #{session_id}
      """,
      host,
      port
    )
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
        error_response("Error serving file: #{inspect(reason)}")
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
      {:error, reasons} -> "FAIL: #{inspect(reasons)}\r\n"
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

        base_url = phlog_base_url(host, port, network)

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

  # === Search Functions ===

  # Search prompt (Type 7)
  defp search_prompt(host, port) do
    """
    iSearch Content\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSearch across all phlog entries and static files.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your search query below:\t\t#{host}\t#{port}
    .
    """
  end

  # Handle search query
  defp handle_search(query, host, port) when byte_size(query) > 0 do
    query = String.trim(query)

    if String.length(query) < 2 do
      """
      i=== Search Results ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      iQuery too short. Please enter at least 2 characters.\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      7Try Again\t/search\t#{host}\t#{port}
      1Back to Main Menu\t/\t#{host}\t#{port}
      .
      """
    else
      results = Search.search(query)

      if Enum.empty?(results) do
        """
        i=== Search Results ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo results found for: "#{query}"\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try Another Search\t/search\t#{host}\t#{port}
        1Back to Main Menu\t/\t#{host}\t#{port}
        .
        """
      else
        result_lines =
          results
          |> Enum.map(fn {type, title, selector, snippet} ->
            type_char = search_result_type(type)
            snippet_line = "i  #{truncate_snippet(snippet, 70)}\t\t#{host}\t#{port}\r\n"
            "#{type_char}#{title}\t#{selector}\t#{host}\t#{port}\r\n#{snippet_line}"
          end)
          |> Enum.join("")

        """
        i=== Search Results ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iQuery: "#{query}"\t\t#{host}\t#{port}
        iFound #{length(results)} result(s)\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{result_lines}i\t\t#{host}\t#{port}
        7New Search\t/search\t#{host}\t#{port}
        1Back to Main Menu\t/\t#{host}\t#{port}
        .
        """
      end
    end
  end

  defp handle_search(_query, host, port) do
    search_prompt(host, port)
  end

  defp search_result_type(:file), do: "0"
  defp search_result_type(:phlog), do: "0"
  defp search_result_type(:dir), do: "1"
  defp search_result_type(_), do: "0"

  defp truncate_snippet(snippet, max_length) do
    if String.length(snippet) > max_length do
      String.slice(snippet, 0, max_length - 3) <> "..."
    else
      snippet
    end
  end

  # === ASCII Art Functions ===

  # ASCII art menu
  defp art_menu(host, port) do
    """
    i=== ASCII Art Generator ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iGenerate ASCII art from text!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Font Styles ---\t\t#{host}\t#{port}
    7Large Block Letters\t/art/text\t#{host}\t#{port}
    7Small Compact Letters\t/art/small\t#{host}\t#{port}
    7Banner with Border\t/art/banner\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Examples ---\t\t#{host}\t#{port}
    0Sample: HELLO\t/art/text HELLO\t#{host}\t#{port}
    0Sample: GOPHER\t/art/banner GOPHER\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  # Art text prompt
  defp art_text_prompt(host, port) do
    """
    iASCII Art - Block Letters\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter text to convert to large block ASCII art.\t\t#{host}\t#{port}
    i(Letters, numbers, and basic punctuation supported)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your text below:\t\t#{host}\t#{port}
    .
    """
  end

  # Art small prompt
  defp art_small_prompt(host, port) do
    """
    iASCII Art - Small Letters\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter text to convert to compact ASCII art.\t\t#{host}\t#{port}
    i(Great for shorter messages)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your text below:\t\t#{host}\t#{port}
    .
    """
  end

  # Art banner prompt
  defp art_banner_prompt(host, port) do
    """
    iASCII Art - Banner\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter text to create a decorated banner.\t\t#{host}\t#{port}
    i(Includes a fancy border around the text)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your text below:\t\t#{host}\t#{port}
    .
    """
  end

  # Handle art text generation
  defp handle_art_text(text, host, port, style) when byte_size(text) > 0 do
    text = String.trim(text) |> String.slice(0, 10)  # Limit to 10 chars
    art = AsciiArt.generate(text, style: style)

    style_name = case style do
      :block -> "Block"
      :small -> "Small"
      _ -> "Default"
    end

    format_text_response(
      """
      === ASCII Art (#{style_name}) ===

      #{art}

      ---
      Text: "#{text}"
      """,
      host,
      port
    )
  end

  defp handle_art_text(_text, host, port, _style) do
    art_text_prompt(host, port)
  end

  # Handle art banner generation
  defp handle_art_banner(text, host, port) when byte_size(text) > 0 do
    text = String.trim(text) |> String.slice(0, 8)  # Limit to 8 chars for banner
    banner = AsciiArt.banner(text)

    format_text_response(
      """
      === ASCII Art Banner ===

      #{banner}

      ---
      Text: "#{text}"
      """,
      host,
      port
    )
  end

  defp handle_art_banner(_text, host, port) do
    art_banner_prompt(host, port)
  end

  # === RAG (Document Query) Functions ===

  defp docs_menu(host, port) do
    stats = Rag.stats()
    docs_dir = Rag.docs_dir()

    """
    i=== Document Knowledge Base ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iQuery your documents with AI-powered search.\t\t#{host}\t#{port}
    iDrop files into #{docs_dir} for auto-ingestion.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Statistics ---\t\t#{host}\t#{port}
    iDocuments: #{stats.documents}\t\t#{host}\t#{port}
    iChunks: #{stats.chunks} (#{stats.embedding_coverage}% embedded)\t\t#{host}\t#{port}
    iEmbedding Model: #{stats.embedding_model}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Actions ---\t\t#{host}\t#{port}
    7Ask a Question\t/docs/ask\t#{host}\t#{port}
    7Search Documents\t/docs/search\t#{host}\t#{port}
    1List All Documents\t/docs/list\t#{host}\t#{port}
    0View Statistics\t/docs/stats\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp docs_list(host, port) do
    documents = Rag.list_documents()

    header = """
    i=== Ingested Documents ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    """

    doc_lines =
      if documents == [] do
        "iNo documents ingested yet.\t\t#{host}\t#{port}\n" <>
        "iDrop files into #{Rag.docs_dir()} to add documents.\t\t#{host}\t#{port}\n"
      else
        documents
        |> Enum.map(fn doc ->
          size_kb = Float.round(doc.size / 1024, 1)
          "0#{doc.filename} (#{size_kb} KB, #{doc.chunk_count} chunks)\t/docs/view/#{doc.id}\t#{host}\t#{port}"
        end)
        |> Enum.join("\n")
      end

    footer = """
    i\t\t#{host}\t#{port}
    1Back to Docs Menu\t/docs\t#{host}\t#{port}
    .
    """

    header <> doc_lines <> "\n" <> footer
  end

  defp docs_stats(host, port) do
    stats = Rag.stats()

    format_text_response("""
    === RAG System Statistics ===

    Documents: #{stats.documents}
    Total Chunks: #{stats.chunks}
    Embedded Chunks: #{stats.embedded_chunks}
    Embedding Coverage: #{stats.embedding_coverage}%

    Embedding Model: #{stats.embedding_model}
    Embeddings Enabled: #{stats.embeddings_enabled}
    Model Loaded: #{stats.embeddings_loaded}

    Docs Directory: #{Rag.docs_dir()}

    Supported Formats:
    - Plain text (.txt, .text)
    - Markdown (.md, .markdown)
    - PDF (.pdf)
    """, host, port)
  end

  defp docs_ask_prompt(host, port) do
    """
    i=== Ask Your Documents ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAsk a question and get an AI-powered answer\t\t#{host}\t#{port}
    ibased on your ingested documents.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter your question:\t/docs/ask\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Docs Menu\t/docs\t#{host}\t#{port}
    .
    """
  end

  defp handle_docs_ask(query, host, port, socket) when byte_size(query) > 0 do
    query = String.trim(query)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      # Stream the response
      ThousandIsland.Socket.send(socket, "Answer (based on your documents):\r\n\r\n")

      case Rag.query_stream(query, fn chunk ->
        ThousandIsland.Socket.send(socket, chunk)
      end) do
        {:ok, _response} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          ThousandIsland.Socket.send(socket, "\r\n\r\n---\r\nGenerated in #{elapsed}ms\r\n.\r\n")
          :streamed

        {:error, reason} ->
          ThousandIsland.Socket.send(socket, "\r\nError: #{inspect(reason)}\r\n.\r\n")
          :streamed
      end
    else
      # Non-streaming response
      case Rag.query(query) do
        {:ok, response} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          Question: #{query}

          Answer (based on your documents):
          #{response}

          ---
          Generated in #{elapsed}ms
          """, host, port)

        {:error, reason} ->
          error_response("Query failed: #{inspect(reason)}")
      end
    end
  end

  defp handle_docs_ask(_query, host, port, _socket) do
    docs_ask_prompt(host, port)
  end

  defp docs_search_prompt(host, port) do
    """
    i=== Search Documents ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iSearch for relevant content in your documents.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Enter search query:\t/docs/search\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Docs Menu\t/docs\t#{host}\t#{port}
    .
    """
  end

  defp handle_docs_search(query, host, port) when byte_size(query) > 0 do
    query = String.trim(query)

    case Rag.search(query, top_k: 10) do
      {:ok, results} when results != [] ->
        header = """
        i=== Search Results for "#{query}" ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iFound #{length(results)} relevant chunks:\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        """

        result_lines =
          results
          |> Enum.with_index(1)
          |> Enum.map(fn {%{chunk: chunk, document: doc, score: score, type: type}, idx} ->
            snippet = String.slice(chunk.content, 0, 100) |> String.replace(~r/\s+/, " ")
            type_label = if type == :semantic, do: "semantic", else: "keyword"
            """
            i#{idx}. #{doc.filename} (#{type_label}, score: #{score})\t\t#{host}\t#{port}
            i   #{snippet}...\t\t#{host}\t#{port}
            0   View document\t/docs/view/#{doc.id}\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            """
          end)
          |> Enum.join("")

        footer = """
        1Back to Docs Menu\t/docs\t#{host}\t#{port}
        .
        """

        header <> result_lines <> footer

      {:ok, []} ->
        """
        i=== Search Results ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo results found for "#{query}"\t\t#{host}\t#{port}
        iTry different keywords or add more documents.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Try another search\t/docs/search\t#{host}\t#{port}
        1Back to Docs Menu\t/docs\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        error_response("Search failed: #{inspect(reason)}")
    end
  end

  defp handle_docs_search(_query, host, port) do
    docs_search_prompt(host, port)
  end

  defp docs_view(doc_id, host, port) do
    case Rag.get_document(doc_id) do
      {:ok, doc} ->
        chunks = PureGopherAi.Rag.DocumentStore.get_chunks(doc_id)

        header = """
        i=== Document: #{doc.filename} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iPath: #{doc.path}\t\t#{host}\t#{port}
        iType: #{doc.type}\t\t#{host}\t#{port}
        iSize: #{Float.round(doc.size / 1024, 1)} KB\t\t#{host}\t#{port}
        iChunks: #{doc.chunk_count}\t\t#{host}\t#{port}
        iIngested: #{DateTime.to_string(doc.ingested_at)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i--- Content Preview (first 3 chunks) ---\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        """

        chunk_previews =
          chunks
          |> Enum.take(3)
          |> Enum.map(fn chunk ->
            preview = String.slice(chunk.content, 0, 200) |> String.replace(~r/\s+/, " ")
            embedded = if chunk.embedding, do: "✓", else: "○"
            "i[#{embedded}] Chunk #{chunk.index}: #{preview}...\t\t#{host}\t#{port}\n"
          end)
          |> Enum.join("")

        footer = """
        i\t\t#{host}\t#{port}
        1Back to Document List\t/docs/list\t#{host}\t#{port}
        1Back to Docs Menu\t/docs\t#{host}\t#{port}
        .
        """

        header <> chunk_previews <> footer

      {:error, :not_found} ->
        error_response("Document not found: #{doc_id}")
    end
  end

  # === AI Services: Summarization Functions ===

  defp handle_phlog_summary(path, host, port, socket) do
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      case Phlog.get_entry(path) do
        {:ok, entry} ->
          header = format_gopher_lines([
            "=== TL;DR: #{entry.title} ===",
            "Date: #{entry.date}",
            "",
            "Summary:"
          ], host, port)
          ThousandIsland.Socket.send(socket, header)

          Summarizer.summarize_phlog_stream(path, fn chunk ->
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
            "Generated in #{elapsed}ms",
            "",
            "=> Full entry: /phlog/entry/#{path}"
          ], host, port)
          ThousandIsland.Socket.send(socket, footer <> ".\r\n")
          :streamed

        {:error, _} ->
          error_response("Phlog entry not found: #{path}")
      end
    else
      case Summarizer.summarize_phlog(path) do
        {:ok, result} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === TL;DR: #{result.title} ===
          Date: #{result.date}

          Summary:
          #{result.summary}

          ---
          Generated in #{elapsed}ms
          Full entry: /phlog/entry/#{path}
          """, host, port)

        {:error, _} ->
          error_response("Failed to summarize phlog entry: #{path}")
      end
    end
  end

  defp handle_doc_summary(doc_id, host, port, socket) do
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      case Rag.get_document(doc_id) do
        {:ok, doc} ->
          header = format_gopher_lines([
            "=== Document Summary: #{doc.filename} ===",
            "",
            "Summary:"
          ], host, port)
          ThousandIsland.Socket.send(socket, header)

          Summarizer.summarize_document_stream(doc_id, fn chunk ->
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
            "Generated in #{elapsed}ms",
            "",
            "=> Full document: /docs/view/#{doc_id}"
          ], host, port)
          ThousandIsland.Socket.send(socket, footer <> ".\r\n")
          :streamed

        {:error, _} ->
          error_response("Document not found: #{doc_id}")
      end
    else
      case Summarizer.summarize_document(doc_id) do
        {:ok, result} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Document Summary: #{result.filename} ===

          Summary:
          #{result.summary}

          ---
          Generated in #{elapsed}ms
          Full document: /docs/view/#{doc_id}
          """, host, port)

        {:error, _} ->
          error_response("Failed to summarize document: #{doc_id}")
      end
    end
  end

  # === AI Services: Translation Functions ===

  defp translate_menu(host, port) do
    languages = Summarizer.supported_languages()

    lang_lines = languages
      |> Enum.map(fn {code, name} ->
        "i  #{code} - #{name}\t\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")

    """
    i=== Translation Service ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTranslate content using AI.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Supported Languages ---\t\t#{host}\t#{port}
    #{lang_lines}
    i\t\t#{host}\t#{port}
    i--- Usage ---\t\t#{host}\t#{port}
    iTranslate phlog:\t\t#{host}\t#{port}
    i  /translate/<lang>/phlog/<path>\t\t#{host}\t#{port}
    iTranslate document:\t\t#{host}\t#{port}
    i  /translate/<lang>/doc/<id>\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Examples ---\t\t#{host}\t#{port}
    0Translate to Spanish\t/translate/es/phlog/2025/01/01-hello\t#{host}\t#{port}
    0Translate to Japanese\t/translate/ja/doc/abc123\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp handle_translate_route(rest, host, port, socket) do
    # Parse: <lang>/phlog/<path> or <lang>/doc/<id>
    case String.split(rest, "/", parts: 3) do
      [lang, "phlog", path] ->
        handle_translate_phlog(lang, path, host, port, socket)

      [lang, "doc", doc_id] ->
        handle_translate_doc(lang, doc_id, host, port, socket)

      _ ->
        error_response("Invalid translation path. Use /translate/<lang>/phlog/<path> or /translate/<lang>/doc/<id>")
    end
  end

  defp handle_translate_phlog(lang, path, host, port, socket) do
    lang_name = Summarizer.language_name(lang)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      case Phlog.get_entry(path) do
        {:ok, entry} ->
          header = format_gopher_lines([
            "=== Translation: #{entry.title} ===",
            "Original: English -> #{lang_name}",
            "",
            "Translated Content:"
          ], host, port)
          ThousandIsland.Socket.send(socket, header)

          Summarizer.translate_phlog_stream(path, lang, fn chunk ->
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
            "Translated to #{lang_name} in #{elapsed}ms",
            "",
            "=> Original: /phlog/entry/#{path}"
          ], host, port)
          ThousandIsland.Socket.send(socket, footer <> ".\r\n")
          :streamed

        {:error, _} ->
          error_response("Phlog entry not found: #{path}")
      end
    else
      case Summarizer.translate_phlog(path, lang) do
        {:ok, result} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Translation: #{result.title} ===
          Original: English -> #{lang_name}

          Translated Content:
          #{result.translated_content}

          ---
          Translated in #{elapsed}ms
          Original: /phlog/entry/#{path}
          """, host, port)

        {:error, _} ->
          error_response("Failed to translate phlog entry: #{path}")
      end
    end
  end

  defp handle_translate_doc(lang, doc_id, host, port, socket) do
    lang_name = Summarizer.language_name(lang)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      case Rag.get_document(doc_id) do
        {:ok, doc} ->
          header = format_gopher_lines([
            "=== Translation: #{doc.filename} ===",
            "Original: English -> #{lang_name}",
            "",
            "Translated Content:"
          ], host, port)
          ThousandIsland.Socket.send(socket, header)

          chunks = PureGopherAi.Rag.DocumentStore.get_chunks(doc_id)
          content = chunks
            |> Enum.map(& &1.content)
            |> Enum.join("\n\n")
            |> String.slice(0, 6000)

          Summarizer.translate_stream(content, lang, fn chunk ->
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
            "Translated to #{lang_name} in #{elapsed}ms",
            "",
            "=> Original: /docs/view/#{doc_id}"
          ], host, port)
          ThousandIsland.Socket.send(socket, footer <> ".\r\n")
          :streamed

        {:error, _} ->
          error_response("Document not found: #{doc_id}")
      end
    else
      case Summarizer.translate_document(doc_id, lang) do
        {:ok, result} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Translation: #{result.filename} ===
          Original: English -> #{lang_name}

          Translated Content:
          #{result.translated_content}

          ---
          Translated in #{elapsed}ms
          Original: /docs/view/#{doc_id}
          """, host, port)

        {:error, _} ->
          error_response("Failed to translate document: #{doc_id}")
      end
    end
  end

  # === AI Services: Dynamic Content Functions ===

  defp handle_digest(host, port, socket) do
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      header = format_gopher_lines([
        "=== Daily Digest ===",
        "AI-generated summary of recent activity",
        "",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      Summarizer.daily_digest_stream(fn chunk ->
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
        "Generated in #{elapsed}ms"
      ], host, port)
      ThousandIsland.Socket.send(socket, footer <> ".\r\n")
      :streamed
    else
      case Summarizer.daily_digest() do
        {:ok, digest} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Daily Digest ===
          AI-generated summary of recent activity

          #{digest}

          ---
          Generated in #{elapsed}ms
          """, host, port)

        {:error, reason} ->
          error_response("Failed to generate digest: #{inspect(reason)}")
      end
    end
  end

  defp handle_topics(host, port, socket) do
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      header = format_gopher_lines([
        "=== Topic Discovery ===",
        "AI-identified themes from your content",
        "",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      case Summarizer.discover_topics() do
        {:ok, topics} ->
          lines = String.split(topics, "\n", trim: false)
          formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
          ThousandIsland.Socket.send(socket, Enum.join(formatted))

          elapsed = System.monotonic_time(:millisecond) - start_time
          footer = format_gopher_lines([
            "",
            "---",
            "Generated in #{elapsed}ms"
          ], host, port)
          ThousandIsland.Socket.send(socket, footer <> ".\r\n")
          :streamed

        {:error, reason} ->
          ThousandIsland.Socket.send(socket, "iError: #{inspect(reason)}\t\t#{host}\t#{port}\r\n.\r\n")
          :streamed
      end
    else
      case Summarizer.discover_topics() do
        {:ok, topics} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Topic Discovery ===
          AI-identified themes from your content

          #{topics}

          ---
          Generated in #{elapsed}ms
          """, host, port)

        {:error, reason} ->
          error_response("Failed to discover topics: #{inspect(reason)}")
      end
    end
  end

  defp discover_prompt(host, port) do
    """
    i=== Content Discovery ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iGet AI-powered content recommendations\t\t#{host}\t#{port}
    ibased on your interests.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a topic or interest:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_discover(interest, host, port, socket) do
    interest = String.trim(interest)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      header = format_gopher_lines([
        "=== Content Recommendations ===",
        "Based on your interest: \"#{interest}\"",
        "",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      case Summarizer.recommend(interest) do
        {:ok, recommendations} ->
          lines = String.split(recommendations, "\n", trim: false)
          formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
          ThousandIsland.Socket.send(socket, Enum.join(formatted))

          elapsed = System.monotonic_time(:millisecond) - start_time
          footer = format_gopher_lines([
            "",
            "---",
            "Generated in #{elapsed}ms"
          ], host, port)
          ThousandIsland.Socket.send(socket, footer <> ".\r\n")
          :streamed

        {:error, reason} ->
          ThousandIsland.Socket.send(socket, "iError: #{inspect(reason)}\t\t#{host}\t#{port}\r\n.\r\n")
          :streamed
      end
    else
      case Summarizer.recommend(interest) do
        {:ok, recommendations} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Content Recommendations ===
          Based on your interest: "#{interest}"

          #{recommendations}

          ---
          Generated in #{elapsed}ms
          """, host, port)

        {:error, reason} ->
          error_response("Failed to get recommendations: #{inspect(reason)}")
      end
    end
  end

  defp explain_prompt(host, port) do
    """
    i=== Explain Mode ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iGet AI-powered explanations for\t\t#{host}\t#{port}
    itechnical terms and concepts.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a term to explain:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_explain(term, host, port, socket) do
    term = String.trim(term)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      header = format_gopher_lines([
        "=== Explanation: #{term} ===",
        "",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      Summarizer.explain_stream(term, fn chunk ->
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
        "Generated in #{elapsed}ms"
      ], host, port)
      ThousandIsland.Socket.send(socket, footer <> ".\r\n")
      :streamed
    else
      case Summarizer.explain(term) do
        {:ok, explanation} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Explanation: #{term} ===

          #{explanation}

          ---
          Generated in #{elapsed}ms
          """, host, port)

        {:error, reason} ->
          error_response("Failed to explain: #{inspect(reason)}")
      end
    end
  end

  # === Gopher Proxy Functions ===

  defp fetch_prompt(host, port) do
    """
    i=== Gopher Proxy ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFetch content from external Gopher servers.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Usage ---\t\t#{host}\t#{port}
    iFetch: /fetch gopher://server/selector\t\t#{host}\t#{port}
    iFetch + Summarize: /fetch-summary gopher://server/selector\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Examples ---\t\t#{host}\t#{port}
    7Fetch Floodgap\t/fetch gopher://gopher.floodgap.com/\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter a Gopher URL:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_fetch(url, host, port) do
    url = String.trim(url)
    Logger.info("[GopherProxy] Fetching: #{url}")

    case GopherProxy.fetch(url) do
      {:ok, result} ->
        format_text_response("""
        === Fetched: #{result.host} ===
        URL: #{result.url}
        Selector: #{result.selector}
        Size: #{result.size} bytes

        --- Content ---
        #{result.content}

        ---
        Fetched successfully
        """, host, port)

      {:error, reason} ->
        error_response("Fetch failed: #{inspect(reason)}")
    end
  end

  defp handle_fetch_summary(url, host, port, socket) do
    url = String.trim(url)
    Logger.info("[GopherProxy] Fetching with summary: #{url}")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      case GopherProxy.fetch(url) do
        {:ok, result} ->
          header = format_gopher_lines([
            "=== Fetched: #{result.host} ===",
            "URL: #{result.url}",
            "Size: #{result.size} bytes",
            "",
            "--- AI Summary ---",
            ""
          ], host, port)
          ThousandIsland.Socket.send(socket, header)

          Summarizer.summarize_text_stream(result.content, fn chunk ->
            if String.length(chunk) > 0 do
              lines = String.split(chunk, "\n", trim: false)
              formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
              ThousandIsland.Socket.send(socket, Enum.join(formatted))
            end
          end, type: "gopher content")

          elapsed = System.monotonic_time(:millisecond) - start_time
          footer = format_gopher_lines([
            "",
            "---",
            "Summarized in #{elapsed}ms"
          ], host, port)
          ThousandIsland.Socket.send(socket, footer <> ".\r\n")
          :streamed

        {:error, reason} ->
          error_response("Fetch failed: #{inspect(reason)}")
      end
    else
      case GopherProxy.fetch_and_summarize(url) do
        {:ok, result} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Fetched: #{result.host} ===
          URL: #{result.url}
          Size: #{result.size} bytes

          --- AI Summary ---
          #{result.summary}

          ---
          Summarized in #{elapsed}ms
          """, host, port)

        {:error, reason} ->
          error_response("Fetch failed: #{inspect(reason)}")
      end
    end
  end

  # === Guestbook Functions ===

  defp guestbook_page(host, port, page) do
    result = Guestbook.list_entries(page: page, per_page: 15)
    stats = Guestbook.stats()

    entries_section = if result.entries == [] do
      "iNo entries yet. Be the first to sign!\t\t#{host}\t#{port}"
    else
      result.entries
      |> Enum.map(fn entry ->
        date = Calendar.strftime(entry.timestamp, "%Y-%m-%d %H:%M UTC")
        message_lines = entry.message
          |> String.split("\n")
          |> Enum.map(&"i  #{&1}\t\t#{host}\t#{port}")
          |> Enum.join("\r\n")

        """
        i--- #{entry.name} (#{date}) ---\t\t#{host}\t#{port}
        #{message_lines}
        i\t\t#{host}\t#{port}
        """
      end)
      |> Enum.join("")
    end

    # Pagination
    pagination = if result.total_pages > 1 do
      pages = for p <- 1..result.total_pages do
        if p == page do
          "i[#{p}]\t\t#{host}\t#{port}"
        else
          "1Page #{p}\t/guestbook/page/#{p}\t#{host}\t#{port}"
        end
      end
      |> Enum.join("\r\n")

      "\r\ni--- Pages ---\t\t#{host}\t#{port}\r\n#{pages}\r\n"
    else
      ""
    end

    """
    i=== Guestbook ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTotal entries: #{stats.total_entries}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Sign the Guestbook\t/guestbook/sign\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Entries (Page #{result.page}/#{result.total_pages}) ---\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{entries_section}#{pagination}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp guestbook_sign_prompt(host, port) do
    """
    i=== Sign the Guestbook ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iLeave a message for other visitors!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: Name | Your message here\t\t#{host}\t#{port}
    iExample: Alice | Hello from the future!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your name and message:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_guestbook_sign(input, host, port, client_ip) do
    input = String.trim(input)

    # Parse "Name | Message" format
    case String.split(input, "|", parts: 2) do
      [name, message] ->
        name = String.trim(name)
        message = String.trim(message)

        case Guestbook.sign(name, message, client_ip) do
          {:ok, entry} ->
            format_text_response("""
            === Thank You! ===

            Your message has been added to the guestbook.

            Name: #{entry.name}
            Message: #{entry.message}
            Time: #{Calendar.strftime(entry.timestamp, "%Y-%m-%d %H:%M UTC")}

            => /guestbook View Guestbook
            => / Back to Main Menu
            """, host, port)

          {:error, :rate_limited, retry_after_ms} ->
            minutes = div(retry_after_ms, 60_000)
            format_text_response("""
            === Please Wait ===

            You can only sign the guestbook once every 5 minutes.
            Please wait #{minutes} more minute(s) before signing again.

            => /guestbook View Guestbook
            => / Back to Main Menu
            """, host, port)

          {:error, :invalid_input} ->
            format_text_response("""
            === Invalid Input ===

            Please provide both a name and message.
            Format: Name | Your message here

            => /guestbook/sign Try Again
            => /guestbook View Guestbook
            """, host, port)
        end

      _ ->
        format_text_response("""
        === Invalid Format ===

        Please use the format: Name | Message
        Example: Alice | Hello from the future!

        => /guestbook/sign Try Again
        => /guestbook View Guestbook
        """, host, port)
    end
  end

  # === Code Assistant Functions ===

  defp code_menu(host, port) do
    """
    i=== Code Assistant ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAI-powered code generation, explanation, and review.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Services ---\t\t#{host}\t#{port}
    7Generate Code\t/code/generate\t#{host}\t#{port}
    7Explain Code\t/code/explain\t#{host}\t#{port}
    7Review Code\t/code/review\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Info ---\t\t#{host}\t#{port}
    1Supported Languages\t/code/languages\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Usage ---\t\t#{host}\t#{port}
    iGenerate: <language> | <description>\t\t#{host}\t#{port}
    iExample: python | fibonacci function\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  defp code_languages(host, port) do
    langs = CodeAssistant.supported_languages()
      |> Enum.map(fn {code, name} -> "i  #{code} - #{name}\t\t#{host}\t#{port}" end)
      |> Enum.join("\r\n")

    """
    i=== Supported Languages ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{langs}
    i\t\t#{host}\t#{port}
    1Back to Code Assistant\t/code\t#{host}\t#{port}
    .
    """
  end

  defp code_generate_prompt(host, port) do
    """
    i=== Generate Code ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: <language> | <description>\t\t#{host}\t#{port}
    iExample: python | function to calculate fibonacci numbers\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter language and description:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_code_generate(input, host, port, socket) do
    input = String.trim(input)
    start_time = System.monotonic_time(:millisecond)

    case String.split(input, "|", parts: 2) do
      [language, description] ->
        language = String.trim(language) |> String.downcase()
        description = String.trim(description)
        lang_name = CodeAssistant.language_name(language)

        if socket && PureGopherAi.AiEngine.streaming_enabled?() do
          header = format_gopher_lines([
            "=== Generated #{lang_name} Code ===",
            "",
            "Task: #{description}",
            "",
            "Code:"
          ], host, port)
          ThousandIsland.Socket.send(socket, header)

          CodeAssistant.generate_stream(language, description, fn chunk ->
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
            "Generated in #{elapsed}ms"
          ], host, port)
          ThousandIsland.Socket.send(socket, footer <> ".\r\n")
          :streamed
        else
          case CodeAssistant.generate(language, description) do
            {:ok, code} ->
              elapsed = System.monotonic_time(:millisecond) - start_time
              format_text_response("""
              === Generated #{lang_name} Code ===

              Task: #{description}

              Code:
              #{code}

              ---
              Generated in #{elapsed}ms
              """, host, port)

            {:error, reason} ->
              error_response("Code generation failed: #{inspect(reason)}")
          end
        end

      _ ->
        format_text_response("""
        === Invalid Format ===

        Please use: <language> | <description>
        Example: python | function to sort a list

        => /code/generate Try Again
        => /code/languages View Supported Languages
        """, host, port)
    end
  end

  defp code_explain_prompt(host, port) do
    """
    i=== Explain Code ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste the code you want explained:\t\t#{host}\t#{port}
    i(Multi-line code works best with Type 7 input)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter code:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_code_explain(input, host, port, socket) do
    code = String.trim(input)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      header = format_gopher_lines([
        "=== Code Explanation ===",
        "",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      CodeAssistant.explain_stream(code, fn chunk ->
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
        "Explained in #{elapsed}ms"
      ], host, port)
      ThousandIsland.Socket.send(socket, footer <> ".\r\n")
      :streamed
    else
      case CodeAssistant.explain(code) do
        {:ok, explanation} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Code Explanation ===

          #{explanation}

          ---
          Explained in #{elapsed}ms
          """, host, port)

        {:error, reason} ->
          error_response("Code explanation failed: #{inspect(reason)}")
      end
    end
  end

  defp code_review_prompt(host, port) do
    """
    i=== Review Code ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPaste the code you want reviewed:\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter code:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_code_review(input, host, port, socket) do
    code = String.trim(input)
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      header = format_gopher_lines([
        "=== Code Review ===",
        "",
        ""
      ], host, port)
      ThousandIsland.Socket.send(socket, header)

      CodeAssistant.review_stream(code, fn chunk ->
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
        "Reviewed in #{elapsed}ms"
      ], host, port)
      ThousandIsland.Socket.send(socket, footer <> ".\r\n")
      :streamed
    else
      case CodeAssistant.review(code) do
        {:ok, review} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          format_text_response("""
          === Code Review ===

          #{review}

          ---
          Reviewed in #{elapsed}ms
          """, host, port)

        {:error, reason} ->
          error_response("Code review failed: #{inspect(reason)}")
      end
    end
  end

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
          error_response("Failed to start adventure: #{inspect(reason)}")
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
            "iError: #{inspect(reason)}\t\t#{host}\t#{port}\r\n.\r\n"
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
          error_response("Adventure action failed: #{inspect(reason)}")
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
            date = if entry.published_at, do: Calendar.strftime(entry.published_at, "%Y-%m-%d"), else: ""
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
        date = if entry.published_at, do: Calendar.strftime(entry.published_at, "%Y-%m-%d %H:%M"), else: "Unknown date"
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
          ThousandIsland.Socket.send(socket, "iError: #{inspect(reason)}\t\t#{host}\t#{port}\r\n")
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
          error_response("Failed to generate digest: #{inspect(reason)}")
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
        last = if feed.last_fetched, do: Calendar.strftime(feed.last_fetched, "%Y-%m-%d %H:%M"), else: "Never"
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
        error_response("Weather error: #{inspect(reason)}")
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
        error_response("Forecast error: #{inspect(reason)}")
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
        error_response("Fortune error: #{inspect(reason)}")
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
        error_response("Fortune error: #{inspect(reason)}")
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
        error_response("Fortune error: #{inspect(reason)}")
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
        ThousandIsland.Socket.send(socket, "iInterpretation failed: #{inspect(reason)}\t\t#{host}\t#{port}\r\n")
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
        error_response("Search error: #{inspect(reason)}")
    end
  end

  defp truncate(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  # === Pastebin Functions ===

  defp paste_menu(host, port) do
    %{active_pastes: active, total_views: views} = Pastebin.stats()

    """
    i=== Pastebin ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iShare text snippets with the Gopher community.\t\t#{host}\t#{port}
    iPastes expire after 1 week by default.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Create New Paste\t/paste/new\t#{host}\t#{port}
    1Recent Pastes\t/paste/recent\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Stats ---\t\t#{host}\t#{port}
    iActive pastes: #{active}\t\t#{host}\t#{port}
    iTotal views: #{views}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Format ---\t\t#{host}\t#{port}
    iTo create a paste, enter your text.\t\t#{host}\t#{port}
    iOptional: Start with "title: Your Title" on first line.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp paste_new_prompt(host, port) do
    """
    i=== Create New Paste ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your text below.\t\t#{host}\t#{port}
    iOptional: Start with "title: Your Title"\t\t#{host}\t#{port}
    iMax size: #{div(Pastebin.max_size(), 1000)}KB\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_paste_create(content, ip, host, port) do
    # Parse optional title from first line
    {title, body} = case String.split(content, "\n", parts: 2) do
      [first_line, rest] ->
        case Regex.run(~r/^title:\s*(.+)$/i, String.trim(first_line)) do
          [_, title] -> {title, rest}
          nil -> {nil, content}
        end
      _ -> {nil, content}
    end

    opts = if title, do: [title: title], else: []

    case Pastebin.create(body, ip, opts) do
      {:ok, id} ->
        """
        i=== Paste Created! ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iPaste ID: #{id}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        0View Paste\t/paste/#{id}\t#{host}\t#{port}
        0Raw Text\t/paste/raw/#{id}\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iShare this link: gopher://#{host}:#{port}/0/paste/#{id}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Create Another\t/paste/new\t#{host}\t#{port}
        1Back to Pastebin\t/paste\t#{host}\t#{port}
        .
        """

      {:error, :too_large} ->
        error_response("Paste too large. Maximum size is #{div(Pastebin.max_size(), 1000)}KB.")

      {:error, :empty_content} ->
        error_response("Cannot create empty paste.")

      {:error, reason} ->
        error_response("Failed to create paste: #{inspect(reason)}")
    end
  end

  defp paste_recent(host, port) do
    case Pastebin.list_recent(20) do
      {:ok, pastes} when pastes == [] ->
        format_text_response("""
        === Recent Pastes ===

        No pastes yet. Be the first to create one!
        """, host, port)

      {:ok, pastes} ->
        paste_lines = pastes
          |> Enum.map(fn p ->
            title = p.title || "Untitled"
            created = String.slice(p.created_at, 0, 10)
            "0[#{created}] #{title} (#{p.lines} lines, #{p.views} views)\t/paste/#{p.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Recent Pastes ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{paste_lines}
        i\t\t#{host}\t#{port}
        7Create New Paste\t/paste/new\t#{host}\t#{port}
        1Back to Pastebin\t/paste\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        error_response("Failed to list pastes: #{inspect(reason)}")
    end
  end

  defp paste_view(id, host, port) do
    case Pastebin.get(id) do
      {:ok, paste} ->
        title = paste.title || "Untitled Paste"
        created = String.slice(paste.created_at, 0, 19) |> String.replace("T", " ")
        expires = String.slice(paste.expires_at, 0, 10)

        format_text_response("""
        === #{title} ===

        ID: #{paste.id}
        Syntax: #{paste.syntax}
        Size: #{paste.size} bytes (#{paste.lines} lines)
        Created: #{created}
        Expires: #{expires}
        Views: #{paste.views}

        ========== Content ==========

        #{paste.content}

        =============================

        Raw: gopher://#{host}:#{port}/0/paste/raw/#{id}
        """, host, port)

      {:error, :not_found} ->
        error_response("Paste not found.")

      {:error, :expired} ->
        error_response("This paste has expired.")

      {:error, reason} ->
        error_response("Failed to get paste: #{inspect(reason)}")
    end
  end

  defp paste_raw(id) do
    case Pastebin.get_raw(id) do
      {:ok, content} ->
        # Return raw text as Type 0
        content <> "\r\n"

      {:error, :not_found} ->
        "Error: Paste not found.\r\n"

      {:error, :expired} ->
        "Error: This paste has expired.\r\n"

      {:error, _} ->
        "Error: Failed to retrieve paste.\r\n"
    end
  end

  # === Polls Functions ===

  defp polls_menu(host, port) do
    %{active_polls: active, total_votes: votes} = Polls.stats()

    """
    i=== Community Polls ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iVote on community polls and create your own!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Active Polls\t/polls/active\t#{host}\t#{port}
    1Closed Polls\t/polls/closed\t#{host}\t#{port}
    7Create New Poll\t/polls/new\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Stats ---\t\t#{host}\t#{port}
    iActive polls: #{active}\t\t#{host}\t#{port}
    iTotal votes cast: #{votes}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp polls_new_prompt(host, port) do
    """
    i=== Create New Poll ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: Question | Option1 | Option2 | Option3 ...\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iExample:\t\t#{host}\t#{port}
    iWhat's your favorite protocol? | Gopher | Gemini | HTTP | All of them\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iMinimum 2 options, maximum 10.\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_polls_create(input, ip, host, port) do
    parts = String.split(input, "|") |> Enum.map(&String.trim/1)

    case parts do
      [question | options] when length(options) >= 2 ->
        case Polls.create(question, options, ip) do
          {:ok, id} ->
            """
            i=== Poll Created! ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iPoll ID: #{id}\t\t#{host}\t#{port}
            iQuestion: #{question}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1View Your Poll\t/polls/#{id}\t#{host}\t#{port}
            1Back to Polls\t/polls\t#{host}\t#{port}
            .
            """

          {:error, :question_too_long} ->
            error_response("Question too long. Maximum 200 characters.")

          {:error, :too_many_options} ->
            error_response("Too many options. Maximum 10 options.")

          {:error, reason} ->
            error_response("Failed to create poll: #{inspect(reason)}")
        end

      _ ->
        error_response("Invalid format. Use: Question | Option1 | Option2 | ...")
    end
  end

  defp polls_active(host, port) do
    case Polls.list_active(20) do
      {:ok, polls} when polls == [] ->
        format_text_response("""
        === Active Polls ===

        No active polls right now.
        Create one to get the conversation started!
        """, host, port)

      {:ok, polls} ->
        poll_lines = polls
          |> Enum.map(fn p ->
            ends = String.slice(p.ends_at, 0, 10)
            "1[#{p.total_votes} votes] #{truncate(p.question, 50)} (ends #{ends})\t/polls/#{p.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Active Polls ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{poll_lines}
        i\t\t#{host}\t#{port}
        7Create New Poll\t/polls/new\t#{host}\t#{port}
        1Back to Polls\t/polls\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        error_response("Failed to list polls: #{inspect(reason)}")
    end
  end

  defp polls_closed(host, port) do
    case Polls.list_closed(20) do
      {:ok, polls} when polls == [] ->
        format_text_response("=== Closed Polls ===\n\nNo closed polls yet.", host, port)

      {:ok, polls} ->
        poll_lines = polls
          |> Enum.map(fn p ->
            "1[#{p.total_votes} votes] #{truncate(p.question, 50)}\t/polls/#{p.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Closed Polls ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{poll_lines}
        i\t\t#{host}\t#{port}
        1Back to Polls\t/polls\t#{host}\t#{port}
        .
        """

      {:error, reason} ->
        error_response("Failed to list polls: #{inspect(reason)}")
    end
  end

  defp polls_view(id, ip, host, port) do
    case Polls.get(id) do
      {:ok, poll} ->
        has_voted = Polls.has_voted?(id, ip)
        status = if poll.closed, do: "CLOSED", else: "ACTIVE"

        # Build option lines with vote counts
        option_lines = poll.options
          |> Enum.with_index()
          |> Enum.map(fn {option, idx} ->
            votes = Enum.at(poll.votes, idx, 0)
            pct = if poll.total_votes > 0, do: round(votes / poll.total_votes * 100), else: 0
            bar = String.duplicate("█", div(pct, 5)) <> String.duplicate("░", 20 - div(pct, 5))

            if poll.closed or has_voted do
              "i  #{idx + 1}. #{option}\t\t#{host}\t#{port}\r\n" <>
              "i     #{bar} #{votes} votes (#{pct}%)\t\t#{host}\t#{port}"
            else
              "1  #{idx + 1}. #{option} [VOTE]\t/polls/vote/#{id}/#{idx}\t#{host}\t#{port}"
            end
          end)
          |> Enum.join("\r\n")

        vote_status = cond do
          poll.closed -> "Poll is closed."
          has_voted -> "You have already voted."
          true -> "Click an option to vote!"
        end

        """
        i=== Poll: #{status} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i#{poll.question}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{option_lines}
        i\t\t#{host}\t#{port}
        iTotal votes: #{poll.total_votes}\t\t#{host}\t#{port}
        i#{vote_status}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Polls\t/polls\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Poll not found.")

      {:error, reason} ->
        error_response("Failed to get poll: #{inspect(reason)}")
    end
  end

  defp handle_polls_vote(rest, ip, host, port) do
    case String.split(rest, "/") do
      [poll_id, option_str] ->
        case Integer.parse(option_str) do
          {option_idx, ""} ->
            case Polls.vote(poll_id, option_idx, ip) do
              {:ok, poll} ->
                """
                i=== Vote Recorded! ===\t\t#{host}\t#{port}
                i\t\t#{host}\t#{port}
                iThank you for voting!\t\t#{host}\t#{port}
                iYou voted for: #{Enum.at(poll.options, option_idx)}\t\t#{host}\t#{port}
                i\t\t#{host}\t#{port}
                1View Results\t/polls/#{poll_id}\t#{host}\t#{port}
                1Back to Polls\t/polls\t#{host}\t#{port}
                .
                """

              {:error, :already_voted} ->
                error_response("You have already voted on this poll.")

              {:error, :poll_closed} ->
                error_response("This poll is closed.")

              {:error, :invalid_option} ->
                error_response("Invalid option.")

              {:error, :not_found} ->
                error_response("Poll not found.")

              {:error, reason} ->
                error_response("Failed to vote: #{inspect(reason)}")
            end

          _ ->
            error_response("Invalid vote format.")
        end

      _ ->
        error_response("Invalid vote URL.")
    end
  end

  # === User Profiles Functions ===

  defp users_menu(host, port) do
    %{total_profiles: total, total_views: views} = UserProfiles.stats()

    """
    i=== User Profiles ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iCreate your own homepage on the Gopher network!\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Browse All Users\t/users/list\t#{host}\t#{port}
    7Search Users\t/users/search\t#{host}\t#{port}
    7Create Your Profile\t/users/create\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Stats ---\t\t#{host}\t#{port}
    iTotal profiles: #{total}\t\t#{host}\t#{port}
    iTotal profile views: #{views}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  defp users_create_prompt(host, port) do
    """
    i=== Create Your Profile ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your desired username:\t\t#{host}\t#{port}
    i(3-20 characters, letters/numbers/underscores, starts with letter)\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iAfter creating your profile, you can visit:\t\t#{host}\t#{port}
    i/users/~yourusername to view it\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_users_create(username, ip, host, port) do
    username = String.trim(username)

    case UserProfiles.create(username, ip) do
      {:ok, _} ->
        """
        i=== Profile Created! ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iWelcome, #{username}!\t\t#{host}\t#{port}
        iYour profile has been created.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1View Your Profile\t/users/~#{username}\t#{host}\t#{port}
        1Back to Users\t/users\t#{host}\t#{port}
        .
        """

      {:error, :rate_limited} ->
        error_response("You can only create one profile per day.")

      {:error, :invalid_username} ->
        error_response("Invalid username. Use letters, numbers, underscores. Must start with a letter.")

      {:error, :username_too_short} ->
        error_response("Username too short. Minimum 3 characters.")

      {:error, :username_too_long} ->
        error_response("Username too long. Maximum 20 characters.")

      {:error, :username_taken} ->
        error_response("That username is already taken.")

      {:error, reason} ->
        error_response("Failed to create profile: #{inspect(reason)}")
    end
  end

  defp users_search_prompt(host, port) do
    """
    i=== Search Users ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter username or interest to search:\t\t#{host}\t#{port}
    .
    """
  end

  defp handle_users_search(query, host, port) do
    case UserProfiles.search(query) do
      {:ok, []} ->
        format_text_response("""
        === Search Results ===

        No users found matching "#{query}".
        """, host, port)

      {:ok, results} ->
        user_lines = results
          |> Enum.map(fn u ->
            interests = Enum.take(u.interests, 3) |> Enum.join(", ")
            interests_text = if interests == "", do: "", else: " (#{interests})"
            "1~#{u.username}#{interests_text}\t/users/~#{u.username}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Search Results for \"#{query}\" ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{user_lines}
        i\t\t#{host}\t#{port}
        7Search Again\t/users/search\t#{host}\t#{port}
        1Back to Users\t/users\t#{host}\t#{port}
        .
        """
    end
  end

  defp users_list(host, port, page) do
    per_page = 20
    offset = (page - 1) * per_page

    case UserProfiles.list(limit: per_page, offset: offset) do
      {:ok, users, total} ->
        total_pages = div(total + per_page - 1, per_page)

        user_lines = if Enum.empty?(users) do
          "iNo profiles yet. Be the first to create one!\t\t#{host}\t#{port}"
        else
          users
          |> Enum.map(fn u ->
            interests = Enum.take(u.interests, 3) |> Enum.join(", ")
            interests_text = if interests == "", do: "", else: " (#{interests})"
            "1~#{u.username}#{interests_text}\t/users/~#{u.username}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")
        end

        pagination = []
        pagination = if page > 1, do: ["1Previous Page\t/users/list/page/#{page - 1}\t#{host}\t#{port}" | pagination], else: pagination
        pagination = if page < total_pages, do: ["1Next Page\t/users/list/page/#{page + 1}\t#{host}\t#{port}" | pagination], else: pagination
        pagination_text = if pagination == [], do: "", else: Enum.join(pagination, "\r\n") <> "\r\n"

        """
        i=== User Profiles (Page #{page}/#{total_pages}) ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{user_lines}
        i\t\t#{host}\t#{port}
        #{pagination_text}7Search Users\t/users/search\t#{host}\t#{port}
        1Back to Users\t/users\t#{host}\t#{port}
        .
        """

      {:error, _} ->
        error_response("Failed to load users.")
    end
  end

  defp users_view(username, host, port) do
    case UserProfiles.get(username) do
      {:ok, profile} ->
        bio_lines = if profile.bio != "" do
          profile.bio
          |> String.split("\n")
          |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")
        else
          "iNo bio yet.\t\t#{host}\t#{port}"
        end

        links_lines = if Enum.empty?(profile.links) do
          "iNo links yet.\t\t#{host}\t#{port}"
        else
          profile.links
          |> Enum.map(fn {title, url} ->
            if String.starts_with?(url, "gopher://") do
              "1#{title}\t#{String.replace(url, "gopher://", "")}\t#{host}\t#{port}"
            else
              "h#{title}\tURL:#{url}\t#{host}\t#{port}"
            end
          end)
          |> Enum.join("\r\n")
        end

        interests_text = if Enum.empty?(profile.interests) do
          "iNone listed.\t\t#{host}\t#{port}"
        else
          profile.interests
          |> Enum.map(fn i -> "i  * #{i}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")
        end

        created = format_date(profile.created_at)

        """
        i=========================================\t\t#{host}\t#{port}
        i   ~#{profile.username}'s Homepage\t\t#{host}\t#{port}
        i=========================================\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i--- About Me ---\t\t#{host}\t#{port}
        #{bio_lines}
        i\t\t#{host}\t#{port}
        i--- Interests ---\t\t#{host}\t#{port}
        #{interests_text}
        i\t\t#{host}\t#{port}
        i--- Links ---\t\t#{host}\t#{port}
        #{links_lines}
        i\t\t#{host}\t#{port}
        i--- Stats ---\t\t#{host}\t#{port}
        iMember since: #{created}\t\t#{host}\t#{port}
        iProfile views: #{profile.views}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Users\t/users\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("User not found: #{username}")
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
            error_response("Failed to create event: #{inspect(reason)}")
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
        error_response("Failed to create short URL: #{inspect(reason)}")
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
    iEnter your username to access your mailbox:\t\t#{host}\t#{port}
    .
    """
  end

  defp mail_inbox(username, host, port) do
    username = String.trim(username)

    case Mailbox.get_inbox(username, limit: 20) do
      {:ok, []} ->
        unread = Mailbox.unread_count(username)

        """
        i=== Inbox: #{username} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo messages yet.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Compose New Message\t/mail/compose/#{username}\t#{host}\t#{port}
        1View Sent Messages\t/mail/sent/#{username}\t#{host}\t#{port}
        1Back to Mailbox\t/mail\t#{host}\t#{port}
        .
        """

      {:ok, messages} ->
        unread = Mailbox.unread_count(username)

        message_lines = messages
          |> Enum.map(fn msg ->
            status = if msg.read, do: "   ", else: "[*]"
            date = format_date(msg.created_at)
            "1#{status} #{truncate(msg.subject, 30)} - from #{msg.from} (#{date})\t/mail/read/#{username}/#{msg.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Inbox: #{username} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iUnread: #{unread} | Total: #{length(messages)}\t\t#{host}\t#{port}
        i[*] = unread\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{message_lines}
        i\t\t#{host}\t#{port}
        7Compose New Message\t/mail/compose/#{username}\t#{host}\t#{port}
        1View Sent Messages\t/mail/sent/#{username}\t#{host}\t#{port}
        1Back to Mailbox\t/mail\t#{host}\t#{port}
        .
        """
    end
  end

  defp mail_sent(username, host, port) do
    case Mailbox.get_sent(username, limit: 20) do
      {:ok, []} ->
        """
        i=== Sent Messages: #{username} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iNo sent messages yet.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Compose New Message\t/mail/compose/#{username}\t#{host}\t#{port}
        1Back to Inbox\t/mail/inbox/#{username}\t#{host}\t#{port}
        .
        """

      {:ok, messages} ->
        message_lines = messages
          |> Enum.map(fn msg ->
            date = format_date(msg.created_at)
            "1#{truncate(msg.subject, 30)} - to #{msg.to} (#{date})\t/mail/read/#{username}/#{msg.id}\t#{host}\t#{port}"
          end)
          |> Enum.join("\r\n")

        """
        i=== Sent Messages: #{username} ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iTotal: #{length(messages)}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        #{message_lines}
        i\t\t#{host}\t#{port}
        7Compose New Message\t/mail/compose/#{username}\t#{host}\t#{port}
        1Back to Inbox\t/mail/inbox/#{username}\t#{host}\t#{port}
        .
        """
    end
  end

  defp mail_read(username, message_id, host, port) do
    case Mailbox.read_message(username, message_id) do
      {:ok, msg} ->
        date = format_date(msg.created_at)
        direction = if msg.to == username, do: "From: #{msg.from}", else: "To: #{msg.to}"

        body_lines = msg.body
          |> String.split("\n")
          |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)
          |> Enum.join("\r\n")

        """
        i=== Message ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iSubject: #{msg.subject}\t\t#{host}\t#{port}
        i#{direction}\t\t#{host}\t#{port}
        iDate: #{date}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        i--- Message ---\t\t#{host}\t#{port}
        #{body_lines}
        i\t\t#{host}\t#{port}
        i--- Actions ---\t\t#{host}\t#{port}
        7Reply to #{msg.from}\t/mail/send/#{username}/#{msg.from}\t#{host}\t#{port}
        1Delete Message\t/mail/delete/#{username}/#{message_id}\t#{host}\t#{port}
        1Back to Inbox\t/mail/inbox/#{username}\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Message not found.")
    end
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
            error_response("Failed to send message: #{inspect(reason)}")
        end

      [_only_subject] ->
        error_response("Invalid format. Use: Subject | Message body")
    end
  end

  defp handle_mail_delete(username, message_id, host, port) do
    case Mailbox.delete_message(username, message_id) do
      :ok ->
        """
        i=== Message Deleted ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iThe message has been deleted.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Back to Inbox\t/mail/inbox/#{username}\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        error_response("Message not found.")
    end
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

  defp trivia_answer_prompt(question_id, host, port) do
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
            date = format_date(t.created_at)
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

  defp board_reply_prompt(board_id, thread_id, host, port) do
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
        Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ ->
        iso_string
    end
  end

  defp format_date(_), do: "unknown"

  # === Admin Functions ===

  # Handle admin routes
  defp handle_admin(path, host, port) do
    if not Admin.enabled?() do
      error_response("Admin interface not configured")
    else
      # Parse token and command from path
      case String.split(path, "/", parts: 2) do
        [token] ->
          # Just token, show admin menu
          if Admin.valid_token?(token) do
            admin_menu(token, host, port)
          else
            error_response("Invalid admin token")
          end

        [token, command] ->
          if Admin.valid_token?(token) do
            handle_admin_command(token, command, host, port)
          else
            error_response("Invalid admin token")
          end

        _ ->
          error_response("Invalid admin path")
      end
    end
  end

  # Admin menu
  defp admin_menu(token, host, port) do
    system_stats = Admin.system_stats()
    cache_stats = Admin.cache_stats()
    rate_stats = Admin.rate_limiter_stats()
    telemetry = Telemetry.format_stats()

    """
    i=== Admin Panel ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- System Status ---\t\t#{host}\t#{port}
    iUptime: #{system_stats.uptime_hours} hours\t\t#{host}\t#{port}
    iProcesses: #{system_stats.processes}\t\t#{host}\t#{port}
    iMemory: #{system_stats.memory.total_mb} MB total\t\t#{host}\t#{port}
    i  Processes: #{system_stats.memory.processes_mb} MB\t\t#{host}\t#{port}
    i  ETS: #{system_stats.memory.ets_mb} MB\t\t#{host}\t#{port}
    i  Binary: #{system_stats.memory.binary_mb} MB\t\t#{host}\t#{port}
    iSchedulers: #{system_stats.schedulers}\t\t#{host}\t#{port}
    iOTP: #{system_stats.otp_version} | Elixir: #{system_stats.elixir_version}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Request Stats ---\t\t#{host}\t#{port}
    iTotal Requests: #{telemetry.total_requests}\t\t#{host}\t#{port}
    iRequests/Hour: #{telemetry.requests_per_hour}\t\t#{host}\t#{port}
    iErrors: #{telemetry.total_errors} (#{telemetry.error_rate}%)\t\t#{host}\t#{port}
    iAvg Latency: #{telemetry.avg_latency_ms}ms\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Cache ---\t\t#{host}\t#{port}
    iSize: #{cache_stats.size}/#{cache_stats.max_size}\t\t#{host}\t#{port}
    iHit Rate: #{cache_stats.hit_rate}%\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Rate Limiter ---\t\t#{host}\t#{port}
    iTracked IPs: #{rate_stats.tracked_ips}\t\t#{host}\t#{port}
    iBanned IPs: #{rate_stats.banned_ips}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- Actions ---\t\t#{host}\t#{port}
    0Clear Cache\t/admin/#{token}/clear-cache\t#{host}\t#{port}
    0Clear Sessions\t/admin/#{token}/clear-sessions\t#{host}\t#{port}
    0Reset Metrics\t/admin/#{token}/reset-metrics\t#{host}\t#{port}
    1View Bans\t/admin/#{token}/bans\t#{host}\t#{port}
    1Manage Documents (RAG)\t/admin/#{token}/docs\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Main Menu\t/\t#{host}\t#{port}
    .
    """
  end

  # Handle admin commands
  defp handle_admin_command(token, "clear-cache", host, port) do
    Admin.clear_cache()
    admin_action_result(token, "Cache cleared successfully", host, port)
  end

  defp handle_admin_command(token, "clear-sessions", host, port) do
    Admin.clear_sessions()
    admin_action_result(token, "All sessions cleared", host, port)
  end

  defp handle_admin_command(token, "reset-metrics", host, port) do
    Admin.reset_metrics()
    admin_action_result(token, "Metrics reset", host, port)
  end

  defp handle_admin_command(token, "bans", host, port) do
    bans = Admin.list_bans()

    ban_lines =
      if Enum.empty?(bans) do
        "iNo banned IPs\t\t#{host}\t#{port}\r\n"
      else
        bans
        |> Enum.map(fn {ip, _timestamp} ->
          "i  #{ip}\t\t#{host}\t#{port}\r\n0Unban #{ip}\t/admin/#{token}/unban/#{ip}\t#{host}\t#{port}\r\n"
        end)
        |> Enum.join("")
      end

    """
    i=== Banned IPs ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{ban_lines}i\t\t#{host}\t#{port}
    7Ban IP\t/admin/#{token}/ban\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Admin\t/admin/#{token}\t#{host}\t#{port}
    .
    """
  end

  defp handle_admin_command(token, "ban\t" <> ip, host, port) do
    handle_ban(token, ip, host, port)
  end

  defp handle_admin_command(token, "ban " <> ip, host, port) do
    handle_ban(token, ip, host, port)
  end

  defp handle_admin_command(token, "unban/" <> ip, host, port) do
    case Admin.unban_ip(ip) do
      :ok ->
        admin_action_result(token, "Unbanned IP: #{ip}", host, port)
      {:error, :invalid_ip} ->
        admin_action_result(token, "Invalid IP address: #{ip}", host, port)
    end
  end

  # RAG admin commands
  defp handle_admin_command(token, "docs", host, port) do
    stats = Rag.stats()
    docs = Rag.list_documents()

    doc_list =
      if docs == [] do
        "iNo documents ingested\t\t#{host}\t#{port}\n"
      else
        docs
        |> Enum.map(fn doc ->
          "i  - #{doc.filename} (#{doc.chunk_count} chunks)\t\t#{host}\t#{port}"
        end)
        |> Enum.join("\n")
      end

    """
    i=== RAG Document Status ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iDocuments: #{stats.documents}\t\t#{host}\t#{port}
    iChunks: #{stats.chunks}\t\t#{host}\t#{port}
    iEmbedding Coverage: #{stats.embedding_coverage}%\t\t#{host}\t#{port}
    iDocs Directory: #{Rag.docs_dir()}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{doc_list}
    i\t\t#{host}\t#{port}
    7Ingest file path\t/admin/#{token}/ingest\t#{host}\t#{port}
    7Ingest URL\t/admin/#{token}/ingest-url\t#{host}\t#{port}
    0Clear all documents\t/admin/#{token}/clear-docs\t#{host}\t#{port}
    0Re-embed all chunks\t/admin/#{token}/reembed\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Admin Menu\t/admin/#{token}\t#{host}\t#{port}
    .
    """
  end

  defp handle_admin_command(token, "ingest\t" <> path, host, port) do
    handle_admin_ingest(token, path, host, port)
  end

  defp handle_admin_command(token, "ingest " <> path, host, port) do
    handle_admin_ingest(token, path, host, port)
  end

  defp handle_admin_command(token, "ingest-url\t" <> url, host, port) do
    handle_admin_ingest_url(token, url, host, port)
  end

  defp handle_admin_command(token, "ingest-url " <> url, host, port) do
    handle_admin_ingest_url(token, url, host, port)
  end

  defp handle_admin_command(token, "clear-docs", host, port) do
    PureGopherAi.Rag.DocumentStore.clear_all()
    admin_action_result(token, "Cleared all documents and chunks", host, port)
  end

  defp handle_admin_command(token, "reembed", host, port) do
    # Clear existing embeddings and re-embed
    PureGopherAi.Rag.Embeddings.embed_all_chunks()
    admin_action_result(token, "Re-embedding all chunks (running in background)", host, port)
  end

  defp handle_admin_command(token, "remove-doc/" <> doc_id, host, port) do
    case Rag.remove(doc_id) do
      :ok ->
        admin_action_result(token, "Removed document: #{doc_id}", host, port)
    end
  end

  defp handle_admin_command(_token, command, host, port) do
    error_response("Unknown admin command: #{command}")
  end

  defp handle_admin_ingest(token, path, host, port) do
    path = String.trim(path)
    case Rag.ingest(path) do
      {:ok, doc} ->
        admin_action_result(token, "Ingested: #{doc.filename} (#{doc.chunk_count} chunks)", host, port)
      {:error, :file_not_found} ->
        admin_action_result(token, "File not found: #{path}", host, port)
      {:error, :already_ingested} ->
        admin_action_result(token, "Already ingested: #{path}", host, port)
      {:error, reason} ->
        admin_action_result(token, "Ingest failed: #{inspect(reason)}", host, port)
    end
  end

  defp handle_admin_ingest_url(token, url, host, port) do
    url = String.trim(url)
    case Rag.ingest_url(url) do
      {:ok, doc} ->
        admin_action_result(token, "Ingested from URL: #{doc.filename} (#{doc.chunk_count} chunks)", host, port)
      {:error, {:http_error, status}} ->
        admin_action_result(token, "HTTP error: #{status}", host, port)
      {:error, reason} ->
        admin_action_result(token, "Ingest failed: #{inspect(reason)}", host, port)
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
    """
    i=== Admin Action ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i#{message}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Admin\t/admin/#{token}\t#{host}\t#{port}
    .
    """
  end

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

  # Stream AI response for /ask (no context)
  defp stream_ai_response(socket, query, _context, host, port, start_time) do
    # Send header
    header = format_gopher_lines(["Query: #{query}", "", "Response:"], host, port)
    ThousandIsland.Socket.send(socket, header)

    # Stream the AI response with proper escaping
    _response = PureGopherAi.AiEngine.generate_stream(query, nil, fn chunk ->
      # Format each chunk as Gopher info line and send
      if String.length(chunk) > 0 do
        # Escape and split chunk by newlines and format each line
        escaped = InputSanitizer.escape_gopher(chunk)
        lines = String.split(escaped, "\r\n", trim: false)
        formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
        ThousandIsland.Socket.send(socket, Enum.join(formatted))
      end
    end)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("AI Response streamed in #{elapsed}ms")

    # Send footer
    footer = format_gopher_lines(["", "---", "Generated in #{elapsed}ms using GPU acceleration (streamed)"], host, port)
    ThousandIsland.Socket.send(socket, footer <> ".\r\n")

    # Return :streamed to indicate we've already sent the response
    :streamed
  end

  # Stream chat response for /chat (with context and session)
  defp stream_chat_response(socket, query, context, session_id, host, port, start_time) do
    # Send header
    header = format_gopher_lines(["You: #{query}", "", "AI:"], host, port)
    ThousandIsland.Socket.send(socket, header)

    # Collect full response for conversation history
    response_chunks = Agent.start_link(fn -> [] end)
    {:ok, response_agent} = response_chunks

    # Stream the AI response with proper escaping
    _response = PureGopherAi.AiEngine.generate_stream(query, context, fn chunk ->
      Agent.update(response_agent, fn chunks -> [chunk | chunks] end)
      if String.length(chunk) > 0 do
        escaped = InputSanitizer.escape_gopher(chunk)
        lines = String.split(escaped, "\r\n", trim: false)
        formatted = Enum.map(lines, &"i#{&1}\t\t#{host}\t#{port}\r\n")
        ThousandIsland.Socket.send(socket, Enum.join(formatted))
      end
    end)

    # Get full response for conversation store
    full_response =
      response_agent
      |> Agent.get(& &1)
      |> Enum.reverse()
      |> Enum.join("")

    Agent.stop(response_agent)

    # Add assistant response to history
    ConversationStore.add_message(session_id, :assistant, full_response)

    # Get updated history for display
    history = ConversationStore.get_history(session_id)
    history_count = length(history)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("Chat response streamed in #{elapsed}ms, history: #{history_count} messages")

    # Send footer
    footer = format_gopher_lines([
      "",
      "---",
      "Session: #{session_id} | Messages: #{history_count}",
      "Generated in #{elapsed}ms (streamed)"
    ], host, port)
    ThousandIsland.Socket.send(socket, footer <> ".\r\n")

    :streamed
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

  # Error response
  defp error_response(message) do
    """
    3#{message}\t\terror.host\t1
    .
    """
  end

  # Rate limit response
  defp rate_limit_response(retry_after_ms) do
    retry_seconds = div(retry_after_ms, 1000) + 1

    """
    3Rate limit exceeded. Please wait #{retry_seconds} seconds.\t\terror.host\t1
    .
    """
  end

  # Banned IP response
  defp banned_response do
    """
    3Access denied. Your IP has been banned.\t\terror.host\t1
    .
    """
  end

  # Blocklisted IP response
  defp blocklisted_response do
    """
    3Access denied. Your IP is on a public blocklist.\t\terror.host\t1
    .
    """
  end
end
