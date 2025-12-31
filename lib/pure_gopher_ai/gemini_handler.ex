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
  alias PureGopherAi.Summarizer
  alias PureGopherAi.GopherProxy
  alias PureGopherAi.Guestbook

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

  # AI Tools - Summarization
  defp route_path("/summary/phlog/" <> path), do: handle_phlog_summary(path)
  defp route_path("/summary/doc/" <> doc_id), do: handle_doc_summary(doc_id)

  # AI Tools - Translation
  defp route_path("/translate"), do: translate_page()
  defp route_path("/translate/" <> rest), do: handle_translate(rest)

  # AI Tools - Dynamic Content
  defp route_path("/digest"), do: handle_digest()
  defp route_path("/topics"), do: handle_topics()
  defp route_path("/discover"), do: input_response("What topics interest you?")
  defp route_path("/discover?" <> query), do: handle_discover(URI.decode(query))
  defp route_path("/explain"), do: input_response("Enter a term to explain:")
  defp route_path("/explain?" <> term), do: handle_explain(URI.decode(term))

  # Gopher Proxy
  defp route_path("/fetch"), do: input_response("Enter a Gopher URL (gopher://...):")
  defp route_path("/fetch?" <> url), do: handle_fetch(URI.decode(url))
  defp route_path("/fetch-summary?" <> url), do: handle_fetch_summary(URI.decode(url))

  # Guestbook
  defp route_path("/guestbook"), do: guestbook_page(1)
  defp route_path("/guestbook/page/" <> page), do: guestbook_page(String.to_integer(page) rescue 1)
  defp route_path("/guestbook/sign"), do: input_response("Enter: Name | Your message")
  defp route_path("/guestbook/sign?" <> input), do: handle_guestbook_sign(URI.decode(input))

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

    ## AI Tools
    => /digest Daily Digest
    => /topics Topic Discovery
    => /discover Content Recommendations
    => /explain Explain a Term
    => /translate Translation Service
    => /fetch Gopher Proxy

    ## Documents
    => /docs Document Knowledge Base
    => /docs/ask Query Your Documents

    ## Content
    => /phlog Phlog (Blog)

    ## Community
    => /guestbook Guestbook

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

        => /summary/phlog/#{path} TL;DR Summary
        => /phlog Back to Phlog
        """)

      {:error, _} ->
        error_response(51, "Phlog entry not found")
    end
  end

  # === AI Tools: Summarization ===

  defp handle_phlog_summary(path) do
    case Summarizer.summarize_phlog(path) do
      {:ok, result} ->
        success_response("""
        # TL;DR: #{result.title}

        #{result.date}

        ## Summary
        #{result.summary}

        => /phlog/#{path} Read Full Entry
        => /phlog Back to Phlog
        """)

      {:error, _} ->
        error_response(51, "Phlog entry not found: #{path}")
    end
  end

  defp handle_doc_summary(doc_id) do
    case Summarizer.summarize_document(doc_id) do
      {:ok, result} ->
        success_response("""
        # Document Summary: #{result.filename}

        ## Summary
        #{result.summary}

        => /docs/view/#{doc_id} View Full Document
        => /docs Back to Documents
        """)

      {:error, _} ->
        error_response(51, "Document not found: #{doc_id}")
    end
  end

  # === AI Tools: Translation ===

  defp translate_page do
    languages = Summarizer.supported_languages()
    |> Enum.map(fn {code, name} -> "* #{code} - #{name}" end)
    |> Enum.join("\n")

    success_response("""
    # Translation Service

    Translate content using AI.

    ## Supported Languages
    #{languages}

    ## Usage
    Translate phlog: /translate/<lang>/phlog/<path>
    Translate document: /translate/<lang>/doc/<id>

    ## Examples
    => /translate/es/phlog/2025/01/01-hello Translate to Spanish
    => /translate/ja/doc/abc123 Translate to Japanese

    => / Back to Home
    """)
  end

  defp handle_translate(rest) do
    case String.split(rest, "/", parts: 3) do
      [lang, "phlog", path] ->
        handle_translate_phlog(lang, path)

      [lang, "doc", doc_id] ->
        handle_translate_doc(lang, doc_id)

      _ ->
        error_response(59, "Invalid translation path. Use /translate/<lang>/phlog/<path> or /translate/<lang>/doc/<id>")
    end
  end

  defp handle_translate_phlog(lang, path) do
    lang_name = Summarizer.language_name(lang)

    case Summarizer.translate_phlog(path, lang) do
      {:ok, result} ->
        success_response("""
        # Translation: #{result.title}

        Original: English -> #{lang_name}

        ## Translated Content
        #{result.translated_content}

        => /phlog/#{path} Original Entry
        => /phlog Back to Phlog
        """)

      {:error, _} ->
        error_response(51, "Phlog entry not found: #{path}")
    end
  end

  defp handle_translate_doc(lang, doc_id) do
    lang_name = Summarizer.language_name(lang)

    case Summarizer.translate_document(doc_id, lang) do
      {:ok, result} ->
        success_response("""
        # Translation: #{result.filename}

        Original: English -> #{lang_name}

        ## Translated Content
        #{result.translated_content}

        => /docs/view/#{doc_id} Original Document
        => /docs Back to Documents
        """)

      {:error, _} ->
        error_response(51, "Document not found: #{doc_id}")
    end
  end

  # === AI Tools: Dynamic Content ===

  defp handle_digest do
    case Summarizer.daily_digest() do
      {:ok, digest} ->
        success_response("""
        # Daily Digest

        AI-generated summary of recent activity.

        #{digest}

        => /phlog Browse All Entries
        => / Back to Home
        """)

      {:error, reason} ->
        error_response(42, "Failed to generate digest: #{inspect(reason)}")
    end
  end

  defp handle_topics do
    case Summarizer.discover_topics() do
      {:ok, topics} ->
        success_response("""
        # Topic Discovery

        AI-identified themes from your content.

        #{topics}

        => /discover Get Recommendations
        => / Back to Home
        """)

      {:error, reason} ->
        error_response(42, "Failed to discover topics: #{inspect(reason)}")
    end
  end

  defp handle_discover(interest) when byte_size(interest) > 0 do
    interest = String.trim(interest)

    case Summarizer.recommend(interest) do
      {:ok, recommendations} ->
        success_response("""
        # Content Recommendations

        Based on your interest: "#{interest}"

        #{recommendations}

        => /discover Try Another Interest
        => / Back to Home
        """)

      {:error, reason} ->
        error_response(42, "Failed to get recommendations: #{inspect(reason)}")
    end
  end

  defp handle_discover(_), do: input_response("What topics interest you?")

  defp handle_explain(term) when byte_size(term) > 0 do
    term = String.trim(term)

    case Summarizer.explain(term) do
      {:ok, explanation} ->
        success_response("""
        # Explanation: #{term}

        #{explanation}

        => /explain Explain Another Term
        => / Back to Home
        """)

      {:error, reason} ->
        error_response(42, "Failed to explain: #{inspect(reason)}")
    end
  end

  defp handle_explain(_), do: input_response("Enter a term to explain:")

  # === Gopher Proxy ===

  defp handle_fetch(url) when byte_size(url) > 0 do
    url = String.trim(url)

    case GopherProxy.fetch(url) do
      {:ok, result} ->
        success_response("""
        # Fetched: #{result.host}

        URL: #{result.url}
        Selector: #{result.selector}
        Size: #{result.size} bytes

        ## Content
        ```
        #{result.content}
        ```

        => /fetch-summary?#{URI.encode(url)} Get AI Summary
        => /fetch Fetch Another URL
        => / Back to Home
        """)

      {:error, reason} ->
        error_response(42, "Fetch failed: #{inspect(reason)}")
    end
  end

  defp handle_fetch(_), do: input_response("Enter a Gopher URL (gopher://...):")

  defp handle_fetch_summary(url) when byte_size(url) > 0 do
    url = String.trim(url)

    case GopherProxy.fetch_and_summarize(url) do
      {:ok, result} ->
        success_response("""
        # Fetched: #{result.host}

        URL: #{result.url}
        Size: #{result.size} bytes

        ## AI Summary
        #{result.summary}

        => /fetch?#{URI.encode(url)} View Full Content
        => /fetch Fetch Another URL
        => / Back to Home
        """)

      {:error, reason} ->
        error_response(42, "Fetch failed: #{inspect(reason)}")
    end
  end

  defp handle_fetch_summary(_), do: input_response("Enter a Gopher URL (gopher://...):")

  # === Guestbook ===

  defp guestbook_page(page) do
    result = Guestbook.list_entries(page: page, per_page: 15)
    stats = Guestbook.stats()

    entries_section = if result.entries == [] do
      "No entries yet. Be the first to sign!"
    else
      result.entries
      |> Enum.map(fn entry ->
        date = Calendar.strftime(entry.timestamp, "%Y-%m-%d %H:%M UTC")
        """
        ### #{entry.name}
        #{date}

        #{entry.message}

        ---
        """
      end)
      |> Enum.join("\n")
    end

    pagination = if result.total_pages > 1 do
      pages = for p <- 1..result.total_pages do
        if p == page do
          "[#{p}]"
        else
          "=> /guestbook/page/#{p} #{p}"
        end
      end
      |> Enum.join(" ")

      "\n## Pages\n#{pages}\n"
    else
      ""
    end

    success_response("""
    # Guestbook

    Total entries: #{stats.total_entries}

    => /guestbook/sign Sign the Guestbook

    ## Entries (Page #{result.page}/#{result.total_pages})

    #{entries_section}
    #{pagination}
    => / Back to Home
    """)
  end

  defp handle_guestbook_sign(input) do
    input = String.trim(input)

    case String.split(input, "|", parts: 2) do
      [name, message] ->
        name = String.trim(name)
        message = String.trim(message)

        # Use a dummy IP for Gemini (we don't have client IP in this context)
        case Guestbook.sign(name, message, {0, 0, 0, 0}) do
          {:ok, entry} ->
            success_response("""
            # Thank You!

            Your message has been added to the guestbook.

            **Name:** #{entry.name}
            **Message:** #{entry.message}
            **Time:** #{Calendar.strftime(entry.timestamp, "%Y-%m-%d %H:%M UTC")}

            => /guestbook View Guestbook
            => / Back to Home
            """)

          {:error, :rate_limited, retry_after_ms} ->
            minutes = div(retry_after_ms, 60_000)
            success_response("""
            # Please Wait

            You can only sign the guestbook once every 5 minutes.
            Please wait #{minutes} more minute(s) before signing again.

            => /guestbook View Guestbook
            => / Back to Home
            """)

          {:error, :invalid_input} ->
            error_response(59, "Invalid input. Please provide both name and message.")
        end

      _ ->
        error_response(59, "Invalid format. Use: Name | Your message")
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip), do: inspect(ip)
end
