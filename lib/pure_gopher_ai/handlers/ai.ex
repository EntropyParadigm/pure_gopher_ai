defmodule PureGopherAi.Handlers.Ai do
  @moduledoc """
  AI-related Gopher handlers.

  Handles /ask, /chat, /models, /personas routes and all AI generation
  with streaming support.
  """

  require Logger

  alias PureGopherAi.ConversationStore
  alias PureGopherAi.ModelRegistry
  alias PureGopherAi.InputSanitizer
  alias PureGopherAi.OutputSanitizer
  alias PureGopherAi.RequestValidator
  alias PureGopherAi.Handlers.Shared

  # === Ask Handlers (Stateless AI Queries) ===

  @doc """
  Prompt for AI query (Type 7 search).
  """
  def ask_prompt(host, port) do
    [
      Shared.info_line("Ask AI a Question", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter your question below:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle AI query with streaming support and security checks.
  """
  def handle_ask(query, host, port, socket) when byte_size(query) > 0 do
    case RequestValidator.validate_query(query) do
      {:ok, _} ->
        case InputSanitizer.sanitize_prompt(query) do
          {:ok, sanitized_query} ->
            Logger.info("AI Query: #{sanitized_query}")
            start_time = System.monotonic_time(:millisecond)

            if socket && PureGopherAi.AiEngine.streaming_enabled?() do
              stream_ai_response(socket, sanitized_query, nil, host, port, start_time)
            else
              response = PureGopherAi.AiEngine.generate(sanitized_query)
              safe_response = OutputSanitizer.sanitize(response)
              elapsed = System.monotonic_time(:millisecond) - start_time
              Logger.info("AI Response generated in #{elapsed}ms")

              Shared.format_text_response(
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
            Shared.format_text_response(
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
        Shared.error_response("Invalid query: #{reason}")
    end
  end

  def handle_ask(_, _host, _port, _socket), do: Shared.error_response("Please provide a query after /ask")

  # === Chat Handlers (With Conversation Memory) ===

  @doc """
  Prompt for chat (Type 7 search).
  """
  def chat_prompt(host, port) do
    [
      Shared.info_line("Chat with AI (Conversation Memory)", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Your conversation history is preserved.", host, port),
      Shared.info_line("Enter your message below:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle chat query with conversation memory, streaming support, and security checks.
  """
  def handle_chat(query, host, port, client_ip, socket) when byte_size(query) > 0 do
    case RequestValidator.validate_query(query) do
      {:ok, _} ->
        case InputSanitizer.sanitize_prompt(query) do
          {:ok, sanitized_query} ->
            session_id = ConversationStore.get_session_id(client_ip)
            Logger.info("Chat query from session #{session_id}: #{sanitized_query}")

            context = ConversationStore.get_context(session_id)
            ConversationStore.add_message(session_id, :user, sanitized_query)

            start_time = System.monotonic_time(:millisecond)

            if socket && PureGopherAi.AiEngine.streaming_enabled?() do
              stream_chat_response(socket, sanitized_query, context, session_id, host, port, start_time)
            else
              response = PureGopherAi.AiEngine.generate(sanitized_query, context)
              safe_response = OutputSanitizer.sanitize(response)
              elapsed = System.monotonic_time(:millisecond) - start_time

              ConversationStore.add_message(session_id, :assistant, safe_response)
              history = ConversationStore.get_history(session_id)
              history_count = length(history)

              Logger.info("Chat response generated in #{elapsed}ms, history: #{history_count} messages")

              Shared.format_text_response(
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
            Shared.format_text_response(
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
        Shared.error_response("Invalid message: #{reason}")
    end
  end

  def handle_chat(_, _host, _port, _ip, _socket), do: Shared.error_response("Please provide a message after /chat")

  @doc """
  Handle conversation clear.
  """
  def handle_clear(host, port, client_ip) do
    session_id = ConversationStore.get_session_id(client_ip)
    ConversationStore.clear(session_id)
    Logger.info("Conversation cleared for session #{session_id}")

    Shared.format_text_response(
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

  # === Models Handlers ===

  @doc """
  Models listing page.
  """
  def models_page(host, port) do
    models = ModelRegistry.list_models()
    default_model = ModelRegistry.default_model()

    model_lines =
      models
      |> Enum.map(fn {id, info} ->
        status = if info.loaded, do: "[Loaded]", else: "[Not loaded]"
        default = if id == default_model, do: " (default)", else: ""

        [
          Shared.info_line("", host, port),
          Shared.info_line("#{info.name}#{default}", host, port),
          Shared.info_line("  #{info.description}", host, port),
          Shared.info_line("  Status: #{status}", host, port),
          Shared.search_line("Ask #{info.name}", "/ask-#{id}", host, port),
          Shared.search_line("Chat with #{info.name}", "/chat-#{id}", host, port)
        ]
      end)

    [
      Shared.info_line("=== Available AI Models ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Models are loaded on first use (lazy loading)", host, port),
      model_lines,
      Shared.info_line("", host, port),
      Shared.link_line("Back to Main Menu", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Parse model ID and query from selector like "gpt2\tquery" or "gpt2 query".
  """
  def parse_model_query(rest) do
    case String.split(rest, "\t", parts: 2) do
      [model_with_query] ->
        case String.split(model_with_query, " ", parts: 2) do
          [model_id, query] -> {model_id, query}
          [model_id] -> {model_id, ""}
        end

      [model_id, query] ->
        {model_id, query}
    end
  end

  @doc """
  Model-specific ask prompt.
  """
  def model_ask_prompt(model_id, host, port) do
    case ModelRegistry.get_model(model_id) do
      nil ->
        Shared.error_response("Unknown model: #{model_id}")

      info ->
        [
          Shared.info_line("Ask #{info.name}", host, port),
          Shared.info_line("", host, port),
          Shared.info_line(info.description, host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Enter your question below:", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()
    end
  end

  @doc """
  Model-specific chat prompt.
  """
  def model_chat_prompt(model_id, host, port) do
    case ModelRegistry.get_model(model_id) do
      nil ->
        Shared.error_response("Unknown model: #{model_id}")

      info ->
        [
          Shared.info_line("Chat with #{info.name}", host, port),
          Shared.info_line("", host, port),
          Shared.info_line(info.description, host, port),
          Shared.info_line("Your conversation history is preserved.", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Enter your message below:", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()
    end
  end

  @doc """
  Handle model-specific ask query.
  """
  def handle_model_ask(model_id, query, host, port, socket) when byte_size(query) > 0 do
    if ModelRegistry.exists?(model_id) do
      Logger.info("AI Query (#{model_id}): #{query}")
      start_time = System.monotonic_time(:millisecond)

      if socket && PureGopherAi.AiEngine.streaming_enabled?() do
        stream_model_response(socket, model_id, query, nil, host, port, start_time)
      else
        response = ModelRegistry.generate(model_id, query)
        elapsed = System.monotonic_time(:millisecond) - start_time
        Logger.info("AI Response (#{model_id}) generated in #{elapsed}ms")

        Shared.format_text_response(
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
      Shared.error_response("Unknown model: #{model_id}")
    end
  end

  def handle_model_ask(model_id, _query, _host, _port, _socket) do
    if ModelRegistry.exists?(model_id) do
      Shared.error_response("Please provide a query after /ask-#{model_id}")
    else
      Shared.error_response("Unknown model: #{model_id}")
    end
  end

  @doc """
  Handle model-specific chat query.
  """
  def handle_model_chat(model_id, query, host, port, client_ip, socket) when byte_size(query) > 0 do
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

        Shared.format_text_response(
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
      Shared.error_response("Unknown model: #{model_id}")
    end
  end

  def handle_model_chat(model_id, _query, _host, _port, _ip, _socket) do
    if ModelRegistry.exists?(model_id) do
      Shared.error_response("Please provide a message after /chat-#{model_id}")
    else
      Shared.error_response("Unknown model: #{model_id}")
    end
  end

  # === Persona Handlers ===

  @doc """
  Personas listing page.
  """
  def personas_page(host, port) do
    personas = PureGopherAi.AiEngine.list_personas()

    persona_lines =
      personas
      |> Enum.map(fn {id, info} ->
        [
          Shared.info_line("", host, port),
          Shared.info_line(info.name, host, port),
          Shared.info_line("  \"#{String.slice(info.prompt, 0..60)}...\"", host, port),
          Shared.search_line("Ask as #{info.name}", "/persona-#{id}", host, port),
          Shared.search_line("Chat as #{info.name}", "/chat-persona-#{id}", host, port)
        ]
      end)

    [
      Shared.info_line("=== Available AI Personas ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Personas modify AI behavior with system prompts", host, port),
      persona_lines,
      Shared.info_line("", host, port),
      Shared.link_line("Back to Main Menu", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Persona ask prompt.
  """
  def persona_ask_prompt(persona_id, host, port) do
    case PureGopherAi.AiEngine.get_persona(persona_id) do
      nil ->
        Shared.error_response("Unknown persona: #{persona_id}")

      info ->
        [
          Shared.info_line("Ask #{info.name}", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("\"#{info.prompt}\"", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Enter your question below:", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()
    end
  end

  @doc """
  Persona chat prompt.
  """
  def persona_chat_prompt(persona_id, host, port) do
    case PureGopherAi.AiEngine.get_persona(persona_id) do
      nil ->
        Shared.error_response("Unknown persona: #{persona_id}")

      info ->
        [
          Shared.info_line("Chat with #{info.name}", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("\"#{info.prompt}\"", host, port),
          Shared.info_line("Your conversation history is preserved.", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Enter your message below:", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()
    end
  end

  @doc """
  Handle persona-specific ask.
  """
  def handle_persona_ask(persona_id, query, host, port, socket) when byte_size(query) > 0 do
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

            Shared.format_text_response(
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
            Shared.error_response("Unknown persona: #{persona_id}")
        end
      end
    else
      Shared.error_response("Unknown persona: #{persona_id}")
    end
  end

  def handle_persona_ask(persona_id, _query, _host, _port, _socket) do
    if PureGopherAi.AiEngine.persona_exists?(persona_id) do
      Shared.error_response("Please provide a query after /persona-#{persona_id}")
    else
      Shared.error_response("Unknown persona: #{persona_id}")
    end
  end

  @doc """
  Handle persona-specific chat.
  """
  def handle_persona_chat(persona_id, query, host, port, client_ip, socket) when byte_size(query) > 0 do
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

            Shared.format_text_response(
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
            Shared.error_response("Unknown persona: #{persona_id}")
        end
      end
    else
      Shared.error_response("Unknown persona: #{persona_id}")
    end
  end

  def handle_persona_chat(persona_id, _query, _host, _port, _ip, _socket) do
    if PureGopherAi.AiEngine.persona_exists?(persona_id) do
      Shared.error_response("Please provide a message after /chat-persona-#{persona_id}")
    else
      Shared.error_response("Unknown persona: #{persona_id}")
    end
  end

  # === Streaming Functions ===

  @doc """
  Stream AI response for /ask (no context).
  """
  def stream_ai_response(socket, query, _context, _host, _port, start_time) do
    # Send header as plain text (type 0 response)
    header = "Query: #{query}\n\nResponse:\n"
    ThousandIsland.Socket.send(socket, header)

    # Use plain text buffered streaming (no host/port spam)
    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    _response = PureGopherAi.AiEngine.generate_stream(query, nil, fn chunk ->
      if String.length(chunk) > 0 do
        streamer.(chunk)
      end
    end)

    # Flush remaining buffer
    flush.()

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("AI Response streamed in #{elapsed}ms")

    footer = "\n\n---\nGenerated in #{elapsed}ms using GPU acceleration (streamed)\n.\r\n"
    ThousandIsland.Socket.send(socket, footer)

    :streamed
  end

  @doc """
  Stream chat response for /chat (with context and session).
  """
  def stream_chat_response(socket, query, context, session_id, _host, _port, start_time) do
    # Send header as plain text (type 0 response)
    header = "You: #{query}\n\nAI:\n"
    ThousandIsland.Socket.send(socket, header)

    {:ok, response_agent} = Agent.start_link(fn -> [] end)

    # Use plain text buffered streaming (no host/port spam)
    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    _response = PureGopherAi.AiEngine.generate_stream(query, context, fn chunk ->
      Agent.update(response_agent, fn chunks -> [chunk | chunks] end)
      if String.length(chunk) > 0 do
        streamer.(chunk)
      end
    end)

    # Flush remaining buffer
    flush.()

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
    Logger.info("Chat response streamed in #{elapsed}ms, history: #{history_count} messages")

    footer = "\n\n---\nSession: #{session_id} | Messages: #{history_count}\nGenerated in #{elapsed}ms (streamed)\n.\r\n"
    ThousandIsland.Socket.send(socket, footer)

    :streamed
  end

  @doc """
  Stream model-specific response.
  """
  def stream_model_response(socket, model_id, query, _context, _host, _port, start_time) do
    # Send header as plain text (type 0 response)
    header = "Query: #{query}\nModel: #{model_id}\n\nResponse:\n"
    ThousandIsland.Socket.send(socket, header)

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    _response = ModelRegistry.generate_stream(model_id, query, nil, fn chunk ->
      if String.length(chunk) > 0 do
        streamer.(chunk)
      end
    end)

    flush.()

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("AI Response (#{model_id}) streamed in #{elapsed}ms")

    footer = "\n\n---\nGenerated in #{elapsed}ms (streamed)\n.\r\n"
    ThousandIsland.Socket.send(socket, footer)

    :streamed
  end

  @doc """
  Stream model-specific chat response.
  """
  def stream_model_chat_response(socket, model_id, query, context, session_id, _host, _port, start_time) do
    # Send header as plain text (type 0 response)
    header = "You: #{query}\nModel: #{model_id}\n\nAI:\n"
    ThousandIsland.Socket.send(socket, header)

    {:ok, response_agent} = Agent.start_link(fn -> [] end)
    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    _response = ModelRegistry.generate_stream(model_id, query, context, fn chunk ->
      Agent.update(response_agent, fn chunks -> [chunk | chunks] end)
      if String.length(chunk) > 0 do
        streamer.(chunk)
      end
    end)

    flush.()

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

    footer = "\n\n---\nSession: #{session_id} | Messages: #{history_count}\nGenerated in #{elapsed}ms (streamed)\n.\r\n"
    ThousandIsland.Socket.send(socket, footer)

    :streamed
  end

  @doc """
  Stream persona response.
  """
  def stream_persona_response(socket, persona_id, query, _context, _host, _port, start_time) do
    # Send header as plain text (type 0 response)
    header = "Query: #{query}\nPersona: #{persona_id}\n\nResponse:\n"
    ThousandIsland.Socket.send(socket, header)

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    case PureGopherAi.AiEngine.generate_stream_with_persona(persona_id, query, nil, fn chunk ->
           if String.length(chunk) > 0 do
             streamer.(chunk)
           end
         end) do
      {:ok, _response} ->
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time
        Logger.info("AI Response (persona: #{persona_id}) streamed in #{elapsed}ms")

        footer = "\n\n---\nGenerated in #{elapsed}ms (streamed)\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\n[Error: Unknown persona]\n.\r\n")
    end

    :streamed
  end

  @doc """
  Stream persona chat response.
  """
  def stream_persona_chat_response(socket, persona_id, query, context, session_id, _host, _port, start_time) do
    # Send header as plain text (type 0 response)
    header = "You: #{query}\nPersona: #{persona_id}\n\nAI:\n"
    ThousandIsland.Socket.send(socket, header)

    {:ok, response_agent} = Agent.start_link(fn -> [] end)
    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    result = PureGopherAi.AiEngine.generate_stream_with_persona(persona_id, query, context, fn chunk ->
      Agent.update(response_agent, fn chunks -> [chunk | chunks] end)
      if String.length(chunk) > 0 do
        streamer.(chunk)
      end
    end)

    flush.()

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

    footer = "\n\n---\nSession: #{session_id} | Messages: #{history_count}\nGenerated in #{elapsed}ms (streamed)\n.\r\n"
    ThousandIsland.Socket.send(socket, footer)

    :streamed
  end
end
