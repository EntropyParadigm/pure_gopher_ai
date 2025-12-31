defmodule PureGopherAi.GeminiHandler do
  @moduledoc """
  Gemini protocol handler (gemini://).

  Gemini is a simple protocol similar to Gopher but with TLS.
  - Port: 1965 (default)
  - Request: gemini://host/path\r\n
  - Response: <status> <meta>\r\n<body>

  Status codes:
  - 10: Input required (meta = prompt)
  - 20: Success (meta = MIME type)
  - 30: Redirect (meta = new URL)
  - 40: Temporary failure
  - 50: Permanent failure
  - 60: Client certificate required
  """

  use ThousandIsland.Handler
  require Logger

  alias PureGopherAi.RateLimiter
  alias PureGopherAi.Telemetry

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

    # Check rate limit
    case RateLimiter.check(client_ip) do
      {:ok, _remaining} ->
        # Parse Gemini request: gemini://host/path\r\n
        request = String.trim(data)
        Logger.info("[Gemini] Request: #{request} from #{format_ip(client_ip)}")

        Telemetry.record_request(request, network: :gemini)

        response = route_request(request)
        ThousandIsland.Socket.send(socket, response)

      {:error, :rate_limited, _retry_after} ->
        Logger.warning("[Gemini] Rate limited: #{format_ip(client_ip)}")
        response = error_response(44, "Rate limited. Please slow down.")
        ThousandIsland.Socket.send(socket, response)

      {:error, :banned} ->
        Logger.warning("[Gemini] Banned IP: #{format_ip(client_ip)}")
        response = error_response(50, "Access denied")
        ThousandIsland.Socket.send(socket, response)

      {:error, :blocklisted} ->
        Logger.warning("[Gemini] Blocklisted IP: #{format_ip(client_ip)}")
        response = error_response(50, "Access denied")
        ThousandIsland.Socket.send(socket, response)
    end

    {:close, state}
  end

  # Route the request
  defp route_request(url) do
    case parse_url(url) do
      {:ok, path} ->
        route_path(path)

      {:error, reason} ->
        error_response(59, "Invalid request: #{reason}")
    end
  end

  defp parse_url(url) do
    # Parse gemini://host/path or just /path
    cond do
      String.starts_with?(url, "gemini://") ->
        case URI.parse(url) do
          %{path: path} when is_binary(path) -> {:ok, path}
          _ -> {:ok, "/"}
        end

      String.starts_with?(url, "/") ->
        {:ok, url}

      url == "" ->
        {:ok, "/"}

      true ->
        {:error, "Invalid URL format"}
    end
  end

  # Route paths
  defp route_path("/"), do: home_page()
  defp route_path(""), do: home_page()

  defp route_path("/ask"), do: input_response("Ask AI a question:")
  defp route_path("/ask?" <> query), do: handle_ask(URI.decode(query))

  defp route_path("/docs"), do: docs_page()
  defp route_path("/docs/ask"), do: input_response("Ask your documents:")
  defp route_path("/docs/ask?" <> query), do: handle_docs_ask(URI.decode(query))

  defp route_path("/about"), do: about_page()
  defp route_path("/stats"), do: stats_page()

  defp route_path("/phlog"), do: phlog_page()
  defp route_path("/phlog/" <> rest), do: phlog_entry(rest)

  defp route_path(path), do: error_response(51, "Not found: #{path}")

  # Response helpers
  defp success_response(content, mime \\ "text/gemini") do
    "20 #{mime}\r\n#{content}"
  end

  defp input_response(prompt) do
    "10 #{prompt}\r\n"
  end

  defp error_response(status, message) do
    "#{status} #{message}\r\n"
  end

  # Pages
  defp home_page do
    success_response("""
    # PureGopherAI

    Welcome to PureGopherAI - An AI-powered Gemini/Gopher server.

    ## AI Services
    => /ask Ask AI a Question

    ## Documents
    => /docs Document Knowledge Base
    => /docs/ask Query Your Documents

    ## Content
    => /phlog Phlog (Blog)

    ## Server
    => /about About this server
    => /stats Server statistics

    ---
    Powered by Elixir + Bumblebee
    """)
  end

  defp about_page do
    backend = Application.get_env(:nx, :default_backend) |> inspect()

    success_response("""
    # About PureGopherAI

    A pure Elixir Gemini/Gopher server with native AI inference.

    ## Features
    * AI text generation via Bumblebee
    * RAG (Retrieval Augmented Generation)
    * Document knowledge base
    * Dual Gopher + Gemini protocol support

    ## Technical
    * Backend: #{backend}
    * Runtime: Elixir #{System.version()}
    * OTP: #{:erlang.system_info(:otp_release)}

    => / Back to Home
    """)
  end

  defp stats_page do
    telemetry = PureGopherAi.Telemetry.format_stats()
    cache = PureGopherAi.ResponseCache.stats()
    rag = PureGopherAi.Rag.stats()

    success_response("""
    # Server Statistics

    ## Requests
    * Total: #{telemetry.total_requests}
    * Per Hour: #{telemetry.requests_per_hour}
    * Errors: #{telemetry.total_errors} (#{telemetry.error_rate}%)
    * Avg Latency: #{telemetry.avg_latency_ms}ms

    ## Cache
    * Size: #{cache.size}/#{cache.max_size}
    * Hit Rate: #{cache.hit_rate}%

    ## RAG
    * Documents: #{rag.documents}
    * Chunks: #{rag.chunks}
    * Embedding Coverage: #{rag.embedding_coverage}%

    => / Back to Home
    """)
  end

  defp docs_page do
    stats = PureGopherAi.Rag.stats()
    docs = PureGopherAi.Rag.list_documents()

    doc_list =
      if docs == [] do
        "No documents ingested yet."
      else
        docs
        |> Enum.map(fn doc ->
          "* #{doc.filename} (#{doc.chunk_count} chunks)"
        end)
        |> Enum.join("\n")
      end

    success_response("""
    # Document Knowledge Base

    Query your documents with AI-powered search.

    ## Statistics
    * Documents: #{stats.documents}
    * Chunks: #{stats.chunks}
    * Embedding Coverage: #{stats.embedding_coverage}%

    ## Documents
    #{doc_list}

    ## Actions
    => /docs/ask Ask your documents a question

    => / Back to Home
    """)
  end

  defp handle_ask(query) when byte_size(query) > 0 do
    query = String.trim(query)
    Logger.info("[Gemini] AI Query: #{query}")

    case PureGopherAi.AiEngine.generate(query) do
      {:ok, response} ->
        success_response("""
        # AI Response

        ## Question
        #{query}

        ## Answer
        #{response}

        => /ask Ask another question
        => / Back to Home
        """)

      {:error, reason} ->
        error_response(42, "AI generation failed: #{inspect(reason)}")
    end
  end

  defp handle_ask(_), do: input_response("Please enter a question:")

  defp handle_docs_ask(query) when byte_size(query) > 0 do
    query = String.trim(query)
    Logger.info("[Gemini] Docs Query: #{query}")

    case PureGopherAi.Rag.query(query) do
      {:ok, response} ->
        success_response("""
        # Document Query Response

        ## Question
        #{query}

        ## Answer
        #{response}

        => /docs/ask Ask another question
        => /docs Back to Documents
        """)

      {:error, reason} ->
        error_response(42, "Query failed: #{inspect(reason)}")
    end
  end

  defp handle_docs_ask(_), do: input_response("Please enter a question about your documents:")

  defp phlog_page do
    result = PureGopherAi.Phlog.list_entries(page: 1, per_page: 20)
    entries = result.entries

    entry_list =
      if entries == [] do
        "No phlog entries yet."
      else
        entries
        |> Enum.map(fn entry ->
          "=> /phlog/#{entry.path} #{entry.date} - #{entry.title}"
        end)
        |> Enum.join("\n")
      end

    success_response("""
    # Phlog

    #{entry_list}

    => / Back to Home
    """)
  end

  defp phlog_entry(path) do
    case PureGopherAi.Phlog.get_entry(path) do
      {:ok, entry} ->
        success_response("""
        # #{entry.title}

        #{entry.date}

        #{entry.content}

        => /phlog Back to Phlog
        """)

      {:error, _} ->
        error_response(51, "Phlog entry not found")
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip), do: inspect(ip)
end
