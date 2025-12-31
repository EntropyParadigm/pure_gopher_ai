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
  alias PureGopherAi.CodeAssistant
  alias PureGopherAi.Adventure
  alias PureGopherAi.FeedAggregator
  alias PureGopherAi.Weather
  alias PureGopherAi.Fortune
  alias PureGopherAi.LinkDirectory
  alias PureGopherAi.BulletinBoard
  alias PureGopherAi.HealthCheck
  alias PureGopherAi.InputSanitizer

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
  defp route_path("/guestbook/page/" <> page), do: guestbook_page(parse_int(page, 1))
  defp route_path("/guestbook/sign"), do: input_response("Enter: Name | Your message")
  defp route_path("/guestbook/sign?" <> input), do: handle_guestbook_sign(URI.decode(input))

  # Code Assistant
  defp route_path("/code"), do: code_menu()
  defp route_path("/code/languages"), do: code_languages()
  defp route_path("/code/generate"), do: input_response("Enter: language | description")
  defp route_path("/code/generate?" <> input), do: handle_code_generate(URI.decode(input))
  defp route_path("/code/explain"), do: input_response("Paste code to explain:")
  defp route_path("/code/explain?" <> input), do: handle_code_explain(URI.decode(input))
  defp route_path("/code/review"), do: input_response("Paste code to review:")
  defp route_path("/code/review?" <> input), do: handle_code_review(URI.decode(input))

  # Text Adventure
  defp route_path("/adventure"), do: adventure_menu()
  defp route_path("/adventure/new"), do: adventure_genres()
  defp route_path("/adventure/new/" <> genre), do: handle_adventure_new(genre)
  defp route_path("/adventure/action"), do: input_response("What do you do?")
  defp route_path("/adventure/action?" <> action), do: handle_adventure_action(URI.decode(action))
  defp route_path("/adventure/look"), do: adventure_look()
  defp route_path("/adventure/inventory"), do: adventure_inventory()
  defp route_path("/adventure/stats"), do: adventure_stats()
  defp route_path("/adventure/save"), do: adventure_save()
  defp route_path("/adventure/load"), do: input_response("Enter save code:")
  defp route_path("/adventure/load?" <> code), do: handle_adventure_load(URI.decode(code))

  # Feed Aggregator
  defp route_path("/feeds"), do: feeds_menu()
  defp route_path("/feeds/digest"), do: feeds_digest()
  defp route_path("/feeds/opml"), do: feeds_opml()
  defp route_path("/feeds/stats"), do: feeds_stats()
  defp route_path("/feeds/" <> rest), do: handle_feed_route(rest)

  # Weather Service
  defp route_path("/weather"), do: input_response("Enter location (e.g., Tokyo, New York):")
  defp route_path("/weather?" <> location), do: handle_weather(URI.decode(location))
  defp route_path("/weather/forecast"), do: input_response("Enter location for 5-day forecast:")
  defp route_path("/weather/forecast?" <> location), do: handle_weather_forecast(URI.decode(location))

  # Fortune/Quote Service
  defp route_path("/fortune"), do: fortune_menu()
  defp route_path("/fortune/random"), do: handle_fortune_random()
  defp route_path("/fortune/today"), do: handle_fortune_of_day()
  defp route_path("/fortune/cookie"), do: handle_fortune_cookie()
  defp route_path("/fortune/category/" <> category), do: handle_fortune_category(category)
  defp route_path("/fortune/interpret"), do: input_response("Enter a quote for AI interpretation (or 'random'):")
  defp route_path("/fortune/interpret?" <> input), do: handle_fortune_interpret(URI.decode(input))
  defp route_path("/fortune/search"), do: input_response("Enter keyword to search quotes:")
  defp route_path("/fortune/search?" <> keyword), do: handle_fortune_search(URI.decode(keyword))

  # Link Directory
  defp route_path("/links"), do: links_menu()
  defp route_path("/links/category/" <> category), do: handle_links_category(category)
  defp route_path("/links/submit"), do: input_response("Enter: URL | Title | Category")
  defp route_path("/links/submit?" <> input), do: handle_links_submit(URI.decode(input))
  defp route_path("/links/search"), do: input_response("Enter keyword to search links:")
  defp route_path("/links/search?" <> query), do: handle_links_search(URI.decode(query))

  # Bulletin Board
  defp route_path("/board"), do: board_menu()
  defp route_path("/board/recent"), do: handle_board_recent()
  defp route_path("/board/" <> rest), do: handle_board_route(rest)

  # Health Check
  defp route_path("/health"), do: health_page()
  defp route_path("/health/live"), do: health_live()
  defp route_path("/health/ready"), do: health_ready()
  defp route_path("/health/json"), do: health_json()

  defp route_path(path), do: error_response(51, "Not found: #{path}")

  # Response helpers
  defp success_response(content, mime \\ "text/gemini") do
    "20 #{mime}\r\n#{content}"
  end

  # Success response with user-generated content (escaped)
  defp success_response_escaped(content, mime \\ "text/gemini") do
    escaped = InputSanitizer.escape_gemini(content)
    "20 #{mime}\r\n#{escaped}"
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
    => /code Code Assistant
    => /weather Weather
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
    => /feeds RSS/Atom Feeds

    ## Community
    => /guestbook Guestbook
    => /adventure Text Adventure
    => /fortune Fortune & Quotes
    => /links Link Directory
    => /board Bulletin Board

    ## Server
    => /about About this server
    => /stats Server statistics
    => /health Health check

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

  # === Code Assistant ===

  defp code_menu do
    langs = CodeAssistant.supported_languages()
      |> Enum.take(10)
      |> Enum.map(fn {code, name} -> "* #{code} - #{name}" end)
      |> Enum.join("\n")

    success_response("""
    # Code Assistant

    AI-powered code generation, explanation, and review.

    ## Services
    => /code/generate Generate Code
    => /code/explain Explain Code
    => /code/review Review Code

    ## Supported Languages (showing first 10)
    #{langs}

    => /code/languages View All Languages

    ## Usage
    Generate: language | description
    Example: python | fibonacci function

    => / Back to Home
    """)
  end

  defp code_languages do
    langs = CodeAssistant.supported_languages()
      |> Enum.map(fn {code, name} -> "* #{code} - #{name}" end)
      |> Enum.join("\n")

    success_response("""
    # Supported Languages

    #{langs}

    => /code Back to Code Assistant
    """)
  end

  defp handle_code_generate(input) do
    input = String.trim(input)

    case String.split(input, "|", parts: 2) do
      [language, description] ->
        language = String.trim(language) |> String.downcase()
        description = String.trim(description)
        lang_name = CodeAssistant.language_name(language)

        case CodeAssistant.generate(language, description) do
          {:ok, code} ->
            success_response("""
            # Generated #{lang_name} Code

            **Task:** #{description}

            ## Code
            ```#{language}
            #{code}
            ```

            => /code/generate Generate More Code
            => /code Back to Code Assistant
            """)

          {:error, reason} ->
            error_response(42, "Code generation failed: #{inspect(reason)}")
        end

      _ ->
        error_response(59, "Invalid format. Use: language | description")
    end
  end

  defp handle_code_explain(code) do
    code = String.trim(code)

    case CodeAssistant.explain(code) do
      {:ok, explanation} ->
        success_response("""
        # Code Explanation

        #{explanation}

        => /code/explain Explain More Code
        => /code Back to Code Assistant
        """)

      {:error, reason} ->
        error_response(42, "Code explanation failed: #{inspect(reason)}")
    end
  end

  defp handle_code_review(code) do
    code = String.trim(code)

    case CodeAssistant.review(code) do
      {:ok, review} ->
        success_response("""
        # Code Review

        #{review}

        => /code/review Review More Code
        => /code Back to Code Assistant
        """)

      {:error, reason} ->
        error_response(42, "Code review failed: #{inspect(reason)}")
    end
  end

  # === Text Adventure ===

  defp adventure_menu do
    session_id = get_session_id()

    case Adventure.get_session(session_id) do
      {:ok, state} ->
        success_response("""
        # Text Adventure

        Current Game: #{state.genre_name}
        Turn: #{state.turn} | Health: #{state.stats.health}/100

        ## Actions
        => /adventure/look Continue Adventure
        => /adventure/action Take Action
        => /adventure/inventory View Inventory
        => /adventure/stats View Stats
        => /adventure/save Save Game

        ## New Game
        => /adventure/new Start New Game
        => /adventure/load Load Saved Game

        => / Back to Home
        """)

      {:error, :not_found} ->
        success_response("""
        # Text Adventure

        Embark on an AI-powered adventure!
        Choose your genre and let the story unfold.

        => /adventure/new Start New Game
        => /adventure/load Load Saved Game

        => / Back to Home
        """)
    end
  end

  defp adventure_genres do
    genres = Adventure.genres()
      |> Enum.map(fn {key, %{name: name, description: desc}} ->
        "=> /adventure/new/#{key} #{name} - #{desc}"
      end)
      |> Enum.join("\n")

    success_response("""
    # Choose Your Adventure

    Select a genre to begin your journey:

    #{genres}

    => /adventure Back
    """)
  end

  defp handle_adventure_new(genre) do
    session_id = get_session_id()

    case Adventure.new_game(session_id, genre) do
      {:ok, state, intro} ->
        success_response("""
        # New Adventure: #{state.genre_name}

        #{intro}

        ---
        Health: #{state.stats.health}/100 | Turn #{state.turn}

        => /adventure/action Take Action
        => /adventure/inventory View Inventory
        => /adventure Menu
        """)

      {:error, reason} ->
        error_response(42, "Failed to start adventure: #{inspect(reason)}")
    end
  end

  defp handle_adventure_action(action) do
    session_id = get_session_id()
    action = String.trim(action)

    case Adventure.take_action(session_id, action) do
      {:ok, state, response} ->
        status = if state.alive do
          "Health: #{state.stats.health}/100 | Turn #{state.turn}"
        else
          "*** GAME OVER ***"
        end

        success_response("""
        # Adventure

        > #{action}

        #{response}

        ---
        #{status}

        => /adventure/action Take Action
        => /adventure/inventory View Inventory
        => /adventure Menu
        """)

      {:error, :no_game} ->
        success_response("""
        # No Active Game

        Start a new adventure to play!

        => /adventure/new Start New Game
        """)

      {:error, :game_over} ->
        success_response("""
        # Game Over

        Your adventure has ended.

        => /adventure/new Start New Game
        """)

      {:error, reason} ->
        error_response(42, "Adventure action failed: #{inspect(reason)}")
    end
  end

  defp adventure_look do
    session_id = get_session_id()

    case Adventure.look(session_id) do
      {:ok, description} ->
        success_response("""
        # Current Scene

        #{description}

        => /adventure/action Take Action
        => /adventure Menu
        """)

      {:error, :not_found} ->
        success_response("""
        # No Active Game

        => /adventure/new Start New Game
        """)

      {:error, :no_context} ->
        success_response("""
        # No Scene Available

        Take an action to continue the story.

        => /adventure/action Take Action
        """)
    end
  end

  defp adventure_inventory do
    session_id = get_session_id()

    case Adventure.inventory(session_id) do
      {:ok, items} ->
        items_list = if length(items) > 0 do
          items
          |> Enum.with_index(1)
          |> Enum.map(fn {item, i} -> "#{i}. #{item}" end)
          |> Enum.join("\n")
        else
          "Your inventory is empty."
        end

        success_response("""
        # Inventory

        #{items_list}

        => /adventure/action Take Action
        => /adventure Menu
        """)

      {:error, :not_found} ->
        success_response("""
        # No Active Game

        => /adventure/new Start New Game
        """)
    end
  end

  defp adventure_stats do
    session_id = get_session_id()

    case Adventure.stats(session_id) do
      {:ok, stats} ->
        success_response("""
        # Character Stats

        * Health: #{stats.health}/100
        * Strength: #{stats.strength}
        * Intelligence: #{stats.intelligence}
        * Luck: #{stats.luck}

        => /adventure/action Take Action
        => /adventure Menu
        """)

      {:error, :not_found} ->
        success_response("""
        # No Active Game

        => /adventure/new Start New Game
        """)
    end
  end

  defp adventure_save do
    session_id = get_session_id()

    case Adventure.save_game(session_id) do
      {:ok, save_code} ->
        success_response("""
        # Save Game

        Copy this save code to restore your game later:

        ```
        #{save_code}
        ```

        => /adventure Menu
        """)

      {:error, :not_found} ->
        success_response("""
        # No Active Game

        No game to save!

        => /adventure/new Start New Game
        """)
    end
  end

  defp handle_adventure_load(code) do
    session_id = get_session_id()
    code = String.trim(code)

    case Adventure.load_game(session_id, code) do
      {:ok, state} ->
        success_response("""
        # Game Loaded

        Welcome back to your #{state.genre_name} adventure!
        Turn: #{state.turn} | Health: #{state.stats.health}/100

        => /adventure/look Continue Adventure
        => /adventure/action Take Action
        => /adventure Menu
        """)

      {:error, :invalid_save} ->
        success_response("""
        # Invalid Save Code

        The save code appears to be corrupted or invalid.

        => /adventure/load Try Again
        => /adventure/new Start New Game
        """)
    end
  end

  # === Feed Aggregator ===

  defp feeds_menu do
    feeds = FeedAggregator.list_feeds()

    feed_lines = if length(feeds) > 0 do
      feeds
      |> Enum.map(fn {id, feed} ->
        "=> /feeds/#{id} #{feed.name}"
      end)
      |> Enum.join("\n")
    else
      "No feeds configured. Add feeds in config.exs"
    end

    success_response("""
    # RSS/Atom Feed Aggregator

    ## Subscribed Feeds
    #{feed_lines}

    ## Actions
    => /feeds/digest AI Digest
    => /feeds/opml OPML Export
    => /feeds/stats Feed Statistics

    => / Back to Home
    """)
  end

  defp handle_feed_route(rest) do
    case String.split(rest, "/", parts: 2) do
      [feed_id] ->
        feed_entries(feed_id)

      [feed_id, "entry/" <> entry_id] ->
        feed_entry(feed_id, entry_id)

      _ ->
        error_response(51, "Invalid feed path")
    end
  end

  defp feed_entries(feed_id) do
    case FeedAggregator.get_feed(feed_id) do
      {:ok, feed} ->
        {:ok, entries} = FeedAggregator.get_entries(feed_id, limit: 30)

        entry_lines = if length(entries) > 0 do
          entries
          |> Enum.map(fn entry ->
            date = if entry.published_at, do: Calendar.strftime(entry.published_at, "%Y-%m-%d"), else: ""
            title = String.slice(entry.title || "Untitled", 0, 60)
            "=> /feeds/#{feed_id}/entry/#{URI.encode(entry.id)} [#{date}] #{title}"
          end)
          |> Enum.join("\n")
        else
          "No entries available."
        end

        success_response("""
        # #{feed.name}

        #{feed.url}

        ## Entries
        #{entry_lines}

        => /feeds Back to Feeds
        """)

      {:error, :not_found} ->
        error_response(51, "Feed not found")
    end
  end

  defp feed_entry(feed_id, entry_id) do
    entry_id = URI.decode(entry_id)

    case FeedAggregator.get_entry(feed_id, entry_id) do
      {:ok, entry} ->
        date = if entry.published_at, do: Calendar.strftime(entry.published_at, "%Y-%m-%d %H:%M"), else: "Unknown date"
        content = entry.content || entry.summary || "No content available."
        content = if String.length(content) > 3000, do: String.slice(content, 0, 3000) <> "...", else: content

        success_response("""
        # #{entry.title}

        **Date:** #{date}
        **Link:** #{entry.link}

        ## Content
        #{content}

        => /feeds/#{feed_id} Back to Feed
        => /feeds All Feeds
        """)

      {:error, :not_found} ->
        error_response(51, "Entry not found")
    end
  end

  defp feeds_digest do
    case FeedAggregator.generate_digest() do
      {:ok, digest} ->
        success_response("""
        # Feed Digest

        #{digest}

        => /feeds Back to Feeds
        """)

      {:error, reason} ->
        error_response(42, "Failed to generate digest: #{inspect(reason)}")
    end
  end

  defp feeds_opml do
    case FeedAggregator.export_opml() do
      {:ok, opml} ->
        success_response("""
        # OPML Export

        ```xml
        #{opml}
        ```

        => /feeds Back to Feeds
        """)
    end
  end

  defp feeds_stats do
    stats = FeedAggregator.stats()

    feed_lines = stats.feeds
      |> Enum.map(fn feed ->
        last = if feed.last_fetched, do: Calendar.strftime(feed.last_fetched, "%Y-%m-%d %H:%M"), else: "Never"
        "* #{feed.name}: #{feed.entries} entries (last: #{last})"
      end)
      |> Enum.join("\n")

    success_response("""
    # Feed Statistics

    * Total Feeds: #{stats.feed_count}
    * Total Entries: #{stats.entry_count}

    ## Per Feed
    #{feed_lines}

    => /feeds Back to Feeds
    """)
  end

  # === Weather Service ===

  defp handle_weather(location) do
    location = String.trim(location)

    case Weather.get_current(location) do
      {:ok, weather} ->
        success_response("""
        # Weather: #{weather.location}

        ```
        #{weather.ascii}
        ```

        #{weather.emoji} **#{weather.description}**

        * Temperature: #{weather.temperature}#{weather.temperature_unit}
        * Feels like: #{weather.feels_like}#{weather.temperature_unit}
        * Humidity: #{weather.humidity}%
        * Wind: #{weather.wind_speed} #{weather.wind_speed_unit} #{weather.wind_direction}

        => /weather Check Another Location
        => /weather/forecast Get 5-Day Forecast
        => / Back to Home
        """)

      {:error, :location_not_found} ->
        error_response(51, "Location not found: #{location}")

      {:error, reason} ->
        error_response(42, "Weather error: #{inspect(reason)}")
    end
  end

  defp handle_weather_forecast(location) do
    location = String.trim(location)

    case Weather.get_forecast(location, 5) do
      {:ok, forecast} ->
        day_lines = forecast.days
          |> Enum.map(fn day ->
            precip = if day.precipitation_probability, do: " (#{day.precipitation_probability}% rain)", else: ""
            "* **#{day.date}**: #{day.emoji} #{day.description}\n  High: #{day.high}#{forecast.temperature_unit} / Low: #{day.low}#{forecast.temperature_unit}#{precip}"
          end)
          |> Enum.join("\n")

        success_response("""
        # 5-Day Forecast: #{forecast.location}

        #{day_lines}

        => /weather Check Another Location
        => / Back to Home
        """)

      {:error, :location_not_found} ->
        error_response(51, "Location not found: #{location}")

      {:error, reason} ->
        error_response(42, "Forecast error: #{inspect(reason)}")
    end
  end

  # Fortune/Quote handlers

  defp fortune_menu do
    {:ok, categories} = Fortune.list_categories()

    category_links = categories
      |> Enum.map(fn cat ->
        "=> /fortune/category/#{cat.id} #{cat.name} (#{cat.count} quotes)"
      end)
      |> Enum.join("\n")

    success_response("""
    # Fortune & Quotes

    > "The future is not something we enter. The future is something we create."
    > - Leonard Sweet

    ## Quick Actions
    => /fortune/random Random Quote
    => /fortune/today Quote of the Day
    => /fortune/cookie Fortune Cookie

    ## Categories
    #{category_links}

    ## AI Features
    => /fortune/interpret AI Interpretation
    => /fortune/search Search Quotes

    => / Back to Home
    """)
  end

  defp handle_fortune_random do
    case Fortune.random() do
      {:ok, {quote, author, category}} ->
        formatted = Fortune.format_cookie_style({quote, author, category})

        success_response("""
        # Random Quote

        Category: #{String.capitalize(category)}

        ```
        #{formatted}
        ```

        => /fortune/random Another Random Quote
        => /fortune Back to Fortune
        """)

      {:error, reason} ->
        error_response(42, "Fortune error: #{inspect(reason)}")
    end
  end

  defp handle_fortune_of_day do
    case Fortune.fortune_of_the_day() do
      {:ok, {quote, author, category}} ->
        formatted = Fortune.format_cookie_style({quote, author, category})
        today = Date.utc_today() |> Date.to_string()

        success_response("""
        # Quote of the Day
        #{today}

        Category: #{String.capitalize(category)}

        ```
        #{formatted}
        ```

        Come back tomorrow for a new quote!

        => /fortune Back to Fortune
        """)

      {:error, reason} ->
        error_response(42, "Fortune error: #{inspect(reason)}")
    end
  end

  defp handle_fortune_cookie do
    case Fortune.fortune_cookie() do
      {:ok, {message, numbers}} ->
        formatted = Fortune.format_fortune_cookie({message, numbers})

        success_response("""
        # Fortune Cookie

        *crack*

        You open the fortune cookie and find...

        ```
        #{formatted}
        ```

        => /fortune/cookie Another Cookie
        => /fortune Back to Fortune
        """)

      {:error, reason} ->
        error_response(42, "Fortune error: #{inspect(reason)}")
    end
  end

  defp handle_fortune_category(category) do
    case Fortune.get_category(category) do
      {:ok, %{name: name, description: desc, quotes: quotes}} ->
        quote_lines = quotes
          |> Enum.take(20)
          |> Enum.map(fn {quote, author} ->
            truncated = if String.length(quote) > 70 do
              String.slice(quote, 0, 67) <> "..."
            else
              quote
            end
            "> \"#{truncated}\"\n> - #{author}"
          end)
          |> Enum.join("\n\n")

        success_response("""
        # #{name}

        #{desc}

        #{length(quotes)} quotes in this category:

        #{quote_lines}

        => /fortune Back to Fortune
        """)

      {:error, :category_not_found} ->
        error_response(51, "Category not found: #{category}")
    end
  end

  defp handle_fortune_interpret(input) do
    input = String.trim(input)

    {quote, author} = if input == "" or String.downcase(input) == "random" do
      case Fortune.random() do
        {:ok, {q, a, _cat}} -> {q, a}
        _ -> {"The journey is the reward.", "Chinese Proverb"}
      end
    else
      {input, "Unknown"}
    end

    case Fortune.interpret({quote, author}) do
      {:ok, interpretation} ->
        success_response("""
        # AI Fortune Interpretation

        > "#{truncate_text(quote, 70)}"
        > - #{author}

        ## The Oracle Speaks...

        #{interpretation}

        => /fortune/interpret Interpret Another
        => /fortune Back to Fortune
        """)

      {:error, reason} ->
        error_response(42, "Interpretation failed: #{inspect(reason)}")
    end
  end

  defp handle_fortune_search(keyword) do
    keyword = String.trim(keyword)

    case Fortune.search(keyword) do
      {:ok, []} ->
        success_response("""
        # Search Results for "#{keyword}"

        No quotes found matching "#{keyword}".

        Try a different search term.

        => /fortune/search Search Again
        => /fortune Back to Fortune
        """)

      {:ok, results} ->
        result_lines = results
          |> Enum.take(15)
          |> Enum.map(fn {quote, author, category} ->
            truncated = if String.length(quote) > 70 do
              String.slice(quote, 0, 67) <> "..."
            else
              quote
            end
            "> [#{category}] \"#{truncated}\"\n> - #{author}"
          end)
          |> Enum.join("\n\n")

        success_response("""
        # Search Results for "#{keyword}"

        Found #{length(results)} quote(s):

        #{result_lines}

        => /fortune/search Search Again
        => /fortune Back to Fortune
        """)

      {:error, reason} ->
        error_response(42, "Search error: #{inspect(reason)}")
    end
  end

  defp truncate_text(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  # Link Directory handlers

  defp links_menu do
    {:ok, categories} = LinkDirectory.list_categories()
    {:ok, stats} = LinkDirectory.stats()

    category_links = categories
      |> Enum.map(fn cat ->
        "=> /links/category/#{cat.id} #{cat.name} (#{cat.count})"
      end)
      |> Enum.join("\n")

    success_response("""
    # Link Directory

    Curated links to Gopher and Gemini sites.

    Total links: #{stats.total}

    ## Categories
    #{category_links}

    ## Actions
    => /links/search Search Links
    => /links/submit Submit a Link

    => / Back to Home
    """)
  end

  defp handle_links_category(category) do
    case LinkDirectory.get_category(category) do
      {:ok, %{info: info, links: links}} ->
        link_lines = links
          |> Enum.map(fn link ->
            desc = if link.description, do: "\n#{truncate_text(link.description, 70)}", else: ""
            "=> #{link.url} #{link.title}#{desc}"
          end)
          |> Enum.join("\n\n")

        success_response("""
        # #{info.name}

        #{info.description}

        #{length(links)} link(s) in this category:

        #{link_lines}

        => /links Back to Directory
        """)

      {:error, :category_not_found} ->
        error_response(51, "Category not found: #{category}")
    end
  end

  defp handle_links_submit(input) do
    case String.split(input, "|") |> Enum.map(&String.trim/1) do
      [url, title, category] when url != "" and title != "" and category != "" ->
        case LinkDirectory.submit_link(url, title, category) do
          {:ok, _id} ->
            success_response("""
            # Link Submitted

            Thank you for your submission!

            * URL: #{url}
            * Title: #{title}
            * Category: #{category}

            Your link will be reviewed and approved soon.

            => /links Back to Directory
            """)

          {:error, :invalid_category} ->
            error_response(50, "Invalid category. Valid: gopher, gemini, tech, retro, programming, art, writing, games, misc")
        end

      _ ->
        error_response(50, "Invalid format. Use: URL | Title | Category")
    end
  end

  defp handle_links_search(query) do
    query = String.trim(query)

    case LinkDirectory.search(query) do
      {:ok, []} ->
        success_response("""
        # Search Results for "#{query}"

        No links found matching "#{query}".

        Try a different search term.

        => /links/search Search Again
        => /links Back to Directory
        """)

      {:ok, results} ->
        result_lines = results
          |> Enum.take(20)
          |> Enum.map(fn link ->
            desc = if link.description, do: "\n#{truncate_text(link.description, 60)}", else: ""
            "> [#{link.category}] #{link.title}#{desc}\n=> #{link.url}"
          end)
          |> Enum.join("\n\n")

        success_response("""
        # Search Results for "#{query}"

        Found #{length(results)} link(s):

        #{result_lines}

        => /links/search Search Again
        => /links Back to Directory
        """)
    end
  end

  # === Bulletin Board ===

  defp board_menu do
    {:ok, boards} = BulletinBoard.list_boards()
    {:ok, stats} = BulletinBoard.stats()

    board_lines = boards
      |> Enum.map(fn board ->
        activity = if board.last_activity do
          " (#{format_board_date(board.last_activity)})"
        else
          ""
        end
        "=> /board/#{board.id} #{board.name} [#{board.thread_count} threads]#{activity}"
      end)
      |> Enum.join("\n")

    success_response("""
    # Bulletin Board

    Community discussions and message boards.

    * Threads: #{stats.total_threads}
    * Posts: #{stats.total_posts}

    ## Boards
    #{board_lines}

    ## Actions
    => /board/recent Recent Posts

    => / Back to Home
    """)
  end

  defp handle_board_route(rest) do
    parts = String.split(rest, "/", parts: 4)

    case parts do
      [board_id] ->
        handle_board_list(board_id, 1)

      [board_id, "page", page_str] ->
        handle_board_list(board_id, parse_int(page_str, 1))

      [board_id, "thread", thread_id] ->
        handle_board_thread(board_id, thread_id)

      [board_id, "new"] ->
        input_response("Enter: Title | Your message")

      [board_id, second] when is_binary(second) ->
        if String.starts_with?(second, "new?") do
          input = String.replace_prefix(second, "new?", "")
          handle_board_new_thread(board_id, URI.decode(input))
        else
          error_response(51, "Invalid board path")
        end

      [board_id, "reply", thread_part] ->
        if String.contains?(thread_part, "?") do
          [thread_id, input] = String.split(thread_part, "?", parts: 2)
          handle_board_reply(board_id, thread_id, URI.decode(input))
        else
          input_response("Enter your reply:")
        end

      _ ->
        error_response(51, "Invalid board path")
    end
  end

  defp handle_board_list(board_id, page) do
    case BulletinBoard.get_board(board_id, page: page, per_page: 20) do
      {:ok, %{info: info, threads: threads, total: total, page: page, total_pages: total_pages}} ->
        thread_lines = if length(threads) > 0 do
          threads
          |> Enum.map(fn thread ->
            date = format_board_date(thread.created_at)
            replies = if thread.reply_count > 0, do: " [#{thread.reply_count} replies]", else: ""
            "=> /board/#{board_id}/thread/#{thread.id} #{thread.title}#{replies}\n  by #{thread.author} - #{date}"
          end)
          |> Enum.join("\n\n")
        else
          "No threads yet. Be the first to start a discussion!"
        end

        pagination = if total_pages > 1 do
          pages = for p <- 1..min(total_pages, 10) do
            if p == page do
              "[#{p}]"
            else
              "=> /board/#{board_id}/page/#{p} #{p}"
            end
          end
          |> Enum.join(" ")

          "\n## Pages (#{page}/#{total_pages})\n#{pages}\n"
        else
          ""
        end

        success_response("""
        # #{info.name}

        #{info.description}

        #{total} thread(s)

        => /board/#{board_id}/new Start New Thread

        ## Threads
        #{thread_lines}
        #{pagination}
        => /board Back to Boards
        """)

      {:error, :board_not_found} ->
        error_response(51, "Board not found: #{board_id}")
    end
  end

  defp handle_board_thread(board_id, thread_id) do
    case BulletinBoard.get_thread(board_id, thread_id) do
      {:ok, %{thread: thread, replies: replies}} ->
        reply_lines = if length(replies) > 0 do
          replies
          |> Enum.with_index(1)
          |> Enum.map(fn {reply, idx} ->
            date = format_board_date(reply.created_at)
            """
            ### ##{idx} - #{reply.author}
            #{date}

            #{reply.body}

            ---
            """
          end)
          |> Enum.join("\n")
        else
          "No replies yet."
        end

        success_response("""
        # #{thread.title}

        **Author:** #{thread.author}
        **Posted:** #{format_board_date(thread.created_at)}

        ---

        #{thread.body}

        ---

        => /board/#{board_id}/reply/#{thread_id} Reply to Thread

        ## Replies (#{length(replies)})

        #{reply_lines}

        => /board/#{board_id} Back to Board
        """)

      {:error, :board_not_found} ->
        error_response(51, "Board not found")

      {:error, :thread_not_found} ->
        error_response(51, "Thread not found")
    end
  end

  defp handle_board_new_thread(board_id, input) do
    case String.split(input, "|", parts: 2) do
      [title, body] ->
        title = String.trim(title)
        body = String.trim(body)

        case BulletinBoard.create_thread(board_id, title, body, "Anonymous") do
          {:ok, thread_id} ->
            success_response("""
            # Thread Created

            Your thread has been posted!

            => /board/#{board_id}/thread/#{thread_id} View Your Thread
            => /board/#{board_id} Back to Board
            """)

          {:error, :board_not_found} ->
            error_response(51, "Board not found")

          {:error, :title_too_long} ->
            error_response(50, "Title too long (max 100 characters)")

          {:error, :body_too_long} ->
            error_response(50, "Message too long (max 4000 characters)")

          {:error, :empty_content} ->
            error_response(50, "Title and message cannot be empty")
        end

      _ ->
        error_response(50, "Invalid format. Use: Title | Your message")
    end
  end

  defp handle_board_reply(board_id, thread_id, body) do
    body = String.trim(body)

    case BulletinBoard.reply(board_id, thread_id, body, "Anonymous") do
      {:ok, _reply_id} ->
        success_response("""
        # Reply Posted

        Your reply has been added to the thread!

        => /board/#{board_id}/thread/#{thread_id} Back to Thread
        """)

      {:error, :board_not_found} ->
        error_response(51, "Board not found")

      {:error, :thread_not_found} ->
        error_response(51, "Thread not found")

      {:error, :body_too_long} ->
        error_response(50, "Reply too long (max 4000 characters)")

      {:error, :empty_content} ->
        error_response(50, "Reply cannot be empty")
    end
  end

  defp handle_board_recent do
    {:ok, posts} = BulletinBoard.recent(20)

    post_lines = if length(posts) > 0 do
      posts
      |> Enum.map(fn post ->
        date = format_board_date(post.created_at)
        type_label = if post.type == :thread, do: "New Thread", else: "Reply"
        title_or_preview = if post.type == :thread do
          post.title
        else
          truncate_text(post.body, 50)
        end

        "* [#{type_label}] #{title_or_preview}\n  in #{post.board_id} by #{post.author} - #{date}"
      end)
      |> Enum.join("\n\n")
    else
      "No recent posts."
    end

    success_response("""
    # Recent Posts

    Latest activity across all boards:

    #{post_lines}

    => /board Back to Boards
    """)
  end

  defp format_board_date(nil), do: "Unknown"
  defp format_board_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> date_string
    end
  end
  defp format_board_date(date), do: inspect(date)

  defp get_session_id do
    # For Gemini, we use a simple hash since we don't have easy access to client IP in handlers
    # In production, this should use proper session management
    :crypto.hash(:sha256, "gemini-adventure-session") |> Base.encode16(case: :lower)
  end

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> default
    end
  end

  # === Health Check ===

  defp health_page do
    success_response("""
    # Health Check

    PureGopherAI Health Status

    #{HealthCheck.status_text()}

    ## Endpoints
    => /health/live Liveness probe
    => /health/ready Readiness probe
    => /health/json JSON status

    => / Back to Home
    """)
  end

  defp health_live do
    case HealthCheck.live() do
      :ok -> success_response("OK")
      _ -> error_response(50, "FAIL")
    end
  end

  defp health_ready do
    case HealthCheck.ready() do
      :ok -> success_response("OK")
      {:error, reasons} -> error_response(50, "FAIL: #{inspect(reasons)}")
    end
  end

  defp health_json do
    "20 application/json\r\n#{HealthCheck.status_json()}"
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip), do: inspect(ip)
end
