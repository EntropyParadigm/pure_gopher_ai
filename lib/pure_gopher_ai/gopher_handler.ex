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
    page = String.to_integer(page_str) rescue 1
    guestbook_page(host, port, page)
  end

  defp route_selector("/guestbook/sign", host, port, _network, _ip, _socket),
    do: guestbook_sign_prompt(host, port)

  defp route_selector("/guestbook/sign\t" <> input, host, port, _network, ip, _socket),
    do: handle_guestbook_sign(input, host, port, ip)

  defp route_selector("/guestbook/sign " <> input, host, port, _network, ip, _socket),
    do: handle_guestbook_sign(input, host, port, ip)

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
    1ASCII Art Generator\t/art\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i=== Community ===\t\t#{host}\t#{port}
    1Guestbook\t/guestbook\t#{host}\t#{port}
    #{files_section}i\t\t#{host}\t#{port}
    i=== Server ===\t\t#{host}\t#{port}
    0About this server\t/about\t#{host}\t#{port}
    0Server statistics\t/stats\t#{host}\t#{port}
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

  # Handle AI query with streaming support
  defp handle_ask(query, host, port, socket) when byte_size(query) > 0 do
    Logger.info("AI Query: #{query}")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      # Stream response to socket
      stream_ai_response(socket, query, nil, host, port, start_time)
    else
      # Non-streaming fallback
      response = PureGopherAi.AiEngine.generate(query)
      elapsed = System.monotonic_time(:millisecond) - start_time
      Logger.info("AI Response generated in #{elapsed}ms")

      format_text_response(
        """
        Query: #{query}

        Response:
        #{response}

        ---
        Generated in #{elapsed}ms using GPU acceleration
        """,
        host,
        port
      )
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

  # Handle chat query with conversation memory and streaming support
  defp handle_chat(query, host, port, client_ip, socket) when byte_size(query) > 0 do
    session_id = ConversationStore.get_session_id(client_ip)
    Logger.info("Chat query from session #{session_id}: #{query}")

    # Get existing conversation context
    context = ConversationStore.get_context(session_id)

    # Add user message to history
    ConversationStore.add_message(session_id, :user, query)

    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      # Stream response to socket with chat context
      stream_chat_response(socket, query, context, session_id, host, port, start_time)
    else
      # Non-streaming fallback
      response = PureGopherAi.AiEngine.generate(query, context)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Add assistant response to history
      ConversationStore.add_message(session_id, :assistant, response)

      # Get updated history for display
      history = ConversationStore.get_history(session_id)
      history_count = length(history)

      Logger.info("Chat response generated in #{elapsed}ms, history: #{history_count} messages")

      format_text_response(
        """
        You: #{query}

        AI: #{response}

        ---
        Session: #{session_id} | Messages: #{history_count}
        Generated in #{elapsed}ms
        """,
        host,
        port
      )
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
        format_text_response(
          """
          === #{entry.title} ===
          Date: #{entry.date}

          #{entry.content}
          ---
          """,
          host,
          port
        )

      {:error, :invalid_path} ->
        error_response("Invalid phlog path")

      {:error, _} ->
        error_response("Phlog entry not found: #{entry_path}")
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
  defp format_text_response(text, host, port) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&"i#{&1}\t\t#{host}\t#{port}")
      |> Enum.join("\r\n")

    lines <> "\r\n.\r\n"
  end

  # Stream AI response for /ask (no context)
  defp stream_ai_response(socket, query, _context, host, port, start_time) do
    # Send header
    header = format_gopher_lines(["Query: #{query}", "", "Response:"], host, port)
    ThousandIsland.Socket.send(socket, header)

    # Stream the AI response
    _response = PureGopherAi.AiEngine.generate_stream(query, nil, fn chunk ->
      # Format each chunk as Gopher info line and send
      if String.length(chunk) > 0 do
        # Split chunk by newlines and format each line
        lines = String.split(chunk, "\n", trim: false)
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

    # Stream the AI response
    _response = PureGopherAi.AiEngine.generate_stream(query, context, fn chunk ->
      Agent.update(response_agent, fn chunks -> [chunk | chunks] end)
      if String.length(chunk) > 0 do
        lines = String.split(chunk, "\n", trim: false)
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

  # Helper to format lines as Gopher info lines
  defp format_gopher_lines(lines, host, port) do
    lines
    |> Enum.map(&"i#{&1}\t\t#{host}\t#{port}\r\n")
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
