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
    i=== Server ===\t\t#{host}\t#{port}
    #{files_section}0About this server\t/about\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iTip: /ask-<model> or /chat-<model> for specific models\t\t#{host}\t#{port}
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
end
