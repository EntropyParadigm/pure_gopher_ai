defmodule PureGopherAi.Handlers.Tools do
  @moduledoc """
  Tool-related Gopher handlers.

  Handles AI-powered tools and utilities:
  - RAG/Documents (/docs)
  - Search (/search)
  - ASCII Art (/art)
  - Summarizer (/summary)
  - Translation (/translate)
  - Content Discovery (/digest, /topics, /discover, /explain)
  - Gopher Proxy (/fetch)
  - Code Assistant (/code)
  """

  require Logger

  alias PureGopherAi.Handlers.Shared
  alias PureGopherAi.Rag
  alias PureGopherAi.Search
  alias PureGopherAi.AsciiArt
  alias PureGopherAi.Summarizer
  alias PureGopherAi.GopherProxy
  alias PureGopherAi.CodeAssistant
  alias PureGopherAi.Phlog
  # Sanitizers available if needed:
  # alias PureGopherAi.InputSanitizer
  # alias PureGopherAi.OutputSanitizer

  # === RAG/Documents Handlers ===

  @doc """
  Documents menu.
  """
  def docs_menu(host, port) do
    stats = Rag.stats()

    [
      Shared.info_line("=== Document Knowledge Base ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Query your documents with AI-enhanced answers.", host, port),
      Shared.info_line("", host, port),
      Shared.search_line("Ask a Question", "/docs/ask", host, port),
      Shared.search_line("Search Documents", "/docs/search", host, port),
      Shared.link_line("List All Documents", "/docs/list", host, port),
      Shared.link_line("Statistics", "/docs/stats", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- Stats ---", host, port),
      Shared.info_line("Documents: #{stats.documents}", host, port),
      Shared.info_line("Chunks: #{stats.chunks}", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Home", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  List all documents.
  """
  def docs_list(host, port) do
    case Rag.list_documents() do
      {:ok, []} ->
        Shared.format_plain_text_response("""
        === Documents ===

        No documents ingested yet.

        Add documents to: #{Rag.docs_dir()}
        """)

      {:ok, docs} ->
        doc_lines = docs
          |> Enum.map(fn doc ->
            Shared.link_line("#{doc.name} (#{doc.chunks} chunks)", "/docs/view/#{doc.id}", host, port)
          end)

        [
          Shared.info_line("=== Documents ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("#{length(docs)} document(s) ingested", host, port),
          Shared.info_line("", host, port),
          doc_lines,
          Shared.info_line("", host, port),
          Shared.link_line("Back to Docs", "/docs", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Shared.error_response("Failed to list documents: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  Documents statistics.
  """
  def docs_stats(_host, _port) do
    stats = Rag.stats()

    Shared.format_plain_text_response("""
    === Document Statistics ===

    Documents: #{stats.document_count}
    Chunks: #{stats.chunk_count}
    Embeddings: #{if stats.embeddings_enabled, do: "Enabled", else: "Disabled"}

    Storage: #{stats.storage_bytes} bytes
    Last Updated: #{stats.last_updated || "Never"}
    """)
  end

  @doc """
  Prompt for asking documents.
  """
  def docs_ask_prompt(host, port) do
    [
      Shared.info_line("=== Ask Your Documents ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter a question about your documents:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle document ask with streaming.
  """
  def handle_docs_ask(query, host, port, socket) do
    Logger.info("RAG Query: #{query}")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      stream_docs_response(socket, query, host, port, start_time)
    else
      case Rag.query(query) do
        {:ok, result} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          Logger.info("RAG Response generated in #{elapsed}ms")

          sources = result.sources
            |> Enum.map(fn s -> "- #{s.name}" end)
            |> Enum.join("\n")

          Shared.format_plain_text_response("""
          Query: #{query}

          Answer:
          #{result.answer}

          Sources:
          #{sources}

          ---
          Generated in #{elapsed}ms
          """)

        {:error, reason} ->
          Shared.error_response("Failed to query: #{Shared.sanitize_error(reason)}")
      end
    end
  end

  @doc """
  Prompt for searching documents.
  """
  def docs_search_prompt(host, port) do
    [
      Shared.info_line("=== Search Documents ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter search terms:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle document search.
  """
  def handle_docs_search(query, host, port) do
    case Rag.search(query) do
      {:ok, []} ->
        Shared.format_plain_text_response("""
        === Search Results ===

        No results found for "#{query}".
        """)

      {:ok, results} ->
        result_lines = results
          |> Enum.take(20)
          |> Enum.map(fn r ->
            preview = String.slice(r.content, 0, 100) |> String.replace("\n", " ")
            preview = if String.length(r.content) > 100, do: preview <> "...", else: preview

            [
              Shared.info_line("--- #{r.document_name} (Score: #{r.score}) ---", host, port),
              Shared.info_line(preview, host, port),
              Shared.link_line("View Document", "/docs/view/#{r.document_id}", host, port),
              Shared.info_line("", host, port)
            ]
          end)

        [
          Shared.info_line("=== Search Results ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Found #{length(results)} result(s) for \"#{query}\"", host, port),
          Shared.info_line("", host, port),
          result_lines,
          Shared.search_line("Search Again", "/docs/search", host, port),
          Shared.link_line("Back to Docs", "/docs", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Shared.error_response("Failed to search: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  View a document.
  """
  def docs_view(doc_id, _host, _port) do
    case Rag.get_document(doc_id) do
      {:ok, doc} ->
        Shared.format_plain_text_response("""
        === #{doc.name} ===

        ID: #{doc.id}
        Type: #{doc.type}
        Size: #{doc.size} bytes
        Chunks: #{doc.chunks}
        Ingested: #{doc.ingested_at}

        --- Preview (first 2000 chars) ---

        #{String.slice(doc.content, 0, 2000)}

        #{if String.length(doc.content) > 2000, do: "[truncated]", else: ""}
        """)

      {:error, :not_found} ->
        Shared.error_response("Document not found.")

      {:error, reason} ->
        Shared.error_response("Failed to get document: #{Shared.sanitize_error(reason)}")
    end
  end

  # === Search Handlers ===

  @doc """
  Search prompt.
  """
  def search_prompt(host, port) do
    [
      Shared.info_line("=== Search Content ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Search phlog entries, documents, and files.", host, port),
      Shared.info_line("Enter your search query:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle search query.
  """
  def handle_search(query, host, port) do
    results = Search.search(query)

    case results do
      [] ->
        Shared.format_plain_text_response("""
        === Search Results ===

        No results found for "#{query}".

        Try different keywords or check spelling.
        """)

      results when is_list(results) ->
        result_lines = results
          |> Enum.take(25)
          |> Enum.map(fn {type, title, selector, _snippet} ->
            type_char = search_result_type(type)
            [type_char, title, "\t", selector, "\t", host, "\t", Integer.to_string(port), "\r\n"]
          end)

        [
          Shared.info_line("=== Search Results ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Found #{length(results)} result(s) for \"#{query}\"", host, port),
          Shared.info_line("", host, port),
          result_lines,
          Shared.info_line("", host, port),
          Shared.search_line("Search Again", "/search", host, port),
          Shared.link_line("Back to Home", "/", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()
    end
  end

  defp search_result_type(:file), do: "0"
  defp search_result_type(:phlog), do: "0"
  defp search_result_type(:dir), do: "1"
  defp search_result_type(_), do: "0"

  # === ASCII Art Handlers ===

  @doc """
  ASCII art menu.
  """
  def art_menu(host, port) do
    [
      Shared.info_line("=== ASCII Art Generator ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Generate ASCII art from text.", host, port),
      Shared.info_line("", host, port),
      Shared.search_line("Large Block Letters", "/art/text", host, port),
      Shared.search_line("Small Compact Letters", "/art/small", host, port),
      Shared.search_line("Banner with Border", "/art/banner", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Home", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Art text prompt.
  """
  def art_text_prompt(host, port) do
    [
      Shared.info_line("=== Large Block Letters ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter text (max 10 chars):", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Art small prompt.
  """
  def art_small_prompt(host, port) do
    [
      Shared.info_line("=== Small Compact Letters ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter text (max 20 chars):", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Art banner prompt.
  """
  def art_banner_prompt(host, port) do
    [
      Shared.info_line("=== Text Banner ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter text for banner:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle art text generation.
  """
  def handle_art_text(text, _host, _port, style) do
    text = String.slice(text, 0, 20)

    art = AsciiArt.generate(text, style: style)

    Shared.format_plain_text_response("""
    === ASCII Art ===

    #{art}

    Text: #{text}
    Style: #{style}
    """)
  end

  @doc """
  Handle art banner generation.
  """
  def handle_art_banner(text, _host, _port) do
    banner = AsciiArt.banner(text)

    Shared.format_plain_text_response("""
    === Banner ===

    #{banner}
    """)
  end

  # === Summarization Handlers ===

  @doc """
  Handle phlog summary with streaming.
  """
  def handle_phlog_summary(path, host, port, socket) do
    case Phlog.get_entry(path) do
      {:ok, entry} ->
        Logger.info("Summarizing phlog: #{path}")
        start_time = System.monotonic_time(:millisecond)

        if socket && PureGopherAi.AiEngine.streaming_enabled?() do
          stream_summary_response(socket, entry.content, "phlog", entry.title, host, port, start_time)
        else
          case Summarizer.summarize_text(entry.content) do
            {:ok, summary} ->
              elapsed = System.monotonic_time(:millisecond) - start_time

              Shared.format_plain_text_response("""
              === TL;DR: #{entry.title} ===

              #{summary}

              ---
              Original: /phlog/entry/#{path}
              Generated in #{elapsed}ms
              """)

            {:error, reason} ->
              Shared.error_response("Failed to summarize: #{Shared.sanitize_error(reason)}")
          end
        end

      {:error, _} ->
        Shared.error_response("Phlog entry not found: #{path}")
    end
  end

  @doc """
  Handle document summary with streaming.
  """
  def handle_doc_summary(doc_id, host, port, socket) do
    case Rag.get_document(doc_id) do
      {:ok, doc} ->
        Logger.info("Summarizing document: #{doc_id}")
        start_time = System.monotonic_time(:millisecond)

        if socket && PureGopherAi.AiEngine.streaming_enabled?() do
          stream_summary_response(socket, doc.content, "document", doc.name, host, port, start_time)
        else
          case Summarizer.summarize_text(doc.content) do
            {:ok, summary} ->
              elapsed = System.monotonic_time(:millisecond) - start_time

              Shared.format_plain_text_response("""
              === TL;DR: #{doc.name} ===

              #{summary}

              ---
              Original: /docs/view/#{doc_id}
              Generated in #{elapsed}ms
              """)

            {:error, reason} ->
              Shared.error_response("Failed to summarize: #{Shared.sanitize_error(reason)}")
          end
        end

      {:error, _} ->
        Shared.error_response("Document not found: #{doc_id}")
    end
  end

  # === Translation Handlers ===

  @doc """
  Translation menu.
  """
  def translate_menu(host, port) do
    languages = Summarizer.supported_languages()

    lang_lines = languages
      |> Enum.take(10)
      |> Enum.map(fn {code, name} ->
        Shared.info_line("#{name} (#{code})", host, port)
      end)

    [
      Shared.info_line("=== Translation Service ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Translate phlog entries and documents.", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Usage:", host, port),
      Shared.info_line("  /translate/<lang>/phlog/<path>", host, port),
      Shared.info_line("  /translate/<lang>/doc/<id>", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Supported languages:", host, port),
      lang_lines,
      Shared.info_line("... and more", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Home", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle translation route parsing.
  """
  def handle_translate_route(rest, host, port, socket) do
    case String.split(rest, "/", parts: 3) do
      [lang, "phlog", path] ->
        handle_phlog_translate(lang, path, host, port, socket)

      [lang, "doc", doc_id] ->
        handle_doc_translate(lang, doc_id, host, port, socket)

      _ ->
        Shared.error_response("Invalid translation path. Use: /translate/<lang>/phlog/<path> or /translate/<lang>/doc/<id>")
    end
  end

  @doc """
  Handle phlog translation.
  """
  def handle_phlog_translate(lang, path, host, port, socket) do
    case Phlog.get_entry(path) do
      {:ok, entry} ->
        Logger.info("Translating phlog #{path} to #{lang}")
        start_time = System.monotonic_time(:millisecond)

        if socket && PureGopherAi.AiEngine.streaming_enabled?() do
          stream_translate_response(socket, entry.content, lang, "phlog", entry.title, host, port, start_time)
        else
          case Summarizer.translate(entry.content, lang) do
            {:ok, translated} ->
              elapsed = System.monotonic_time(:millisecond) - start_time

              Shared.format_plain_text_response("""
              === #{entry.title} (#{lang}) ===

              #{translated}

              ---
              Original: /phlog/entry/#{path}
              Translated in #{elapsed}ms
              """)

            {:error, reason} ->
              Shared.error_response("Failed to translate: #{Shared.sanitize_error(reason)}")
          end
        end

      {:error, _} ->
        Shared.error_response("Phlog entry not found: #{path}")
    end
  end

  @doc """
  Handle document translation.
  """
  def handle_doc_translate(lang, doc_id, host, port, socket) do
    case Rag.get_document(doc_id) do
      {:ok, doc} ->
        Logger.info("Translating document #{doc_id} to #{lang}")
        start_time = System.monotonic_time(:millisecond)

        if socket && PureGopherAi.AiEngine.streaming_enabled?() do
          stream_translate_response(socket, doc.content, lang, "document", doc.name, host, port, start_time)
        else
          case Summarizer.translate(doc.content, lang) do
            {:ok, translated} ->
              elapsed = System.monotonic_time(:millisecond) - start_time

              Shared.format_plain_text_response("""
              === #{doc.name} (#{lang}) ===

              #{translated}

              ---
              Original: /docs/view/#{doc_id}
              Translated in #{elapsed}ms
              """)

            {:error, reason} ->
              Shared.error_response("Failed to translate: #{Shared.sanitize_error(reason)}")
          end
        end

      {:error, _} ->
        Shared.error_response("Document not found: #{doc_id}")
    end
  end

  # === Content Discovery Handlers ===

  @doc """
  Handle daily digest.
  """
  def handle_digest(host, port, socket) do
    Logger.info("Generating daily digest")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      stream_digest_response(socket, host, port, start_time)
    else
      case Summarizer.daily_digest() do
        {:ok, digest} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          Shared.format_plain_text_response("""
          === Daily Digest ===

          #{digest}

          ---
          Generated in #{elapsed}ms
          """)

        {:error, reason} ->
          Shared.error_response("Failed to generate digest: #{Shared.sanitize_error(reason)}")
      end
    end
  end

  @doc """
  Discover prompt.
  """
  def discover_prompt(host, port) do
    [
      Shared.info_line("=== Content Discovery ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter your interests for personalized recommendations:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle content discovery.
  """
  def handle_discover(interest, host, port, socket) do
    Logger.info("Discovering content for: #{interest}")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      stream_discover_response(socket, interest, host, port, start_time)
    else
      case Summarizer.recommend(interest) do
        {:ok, recommendations} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          Shared.format_plain_text_response("""
          === Recommendations for "#{interest}" ===

          #{recommendations}

          ---
          Generated in #{elapsed}ms
          """)

        {:error, reason} ->
          Shared.error_response("Failed to get recommendations: #{Shared.sanitize_error(reason)}")
      end
    end
  end

  @doc """
  Explain prompt.
  """
  def explain_prompt(host, port) do
    [
      Shared.info_line("=== Explain a Term ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter a term or concept to explain:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle explain request.
  """
  def handle_explain(term, host, port, socket) do
    Logger.info("Explaining: #{term}")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      stream_explain_response(socket, term, host, port, start_time)
    else
      case Summarizer.explain(term) do
        {:ok, explanation} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          Shared.format_plain_text_response("""
          === #{term} ===

          #{explanation}

          ---
          Generated in #{elapsed}ms
          """)

        {:error, reason} ->
          Shared.error_response("Failed to explain: #{Shared.sanitize_error(reason)}")
      end
    end
  end

  @doc """
  Handle topics discovery.
  """
  def handle_topics(host, port, socket) do
    Logger.info("Discovering topics")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      stream_topics_response(socket, host, port, start_time)
    else
      case Summarizer.discover_topics() do
        {:ok, topics} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          Shared.format_plain_text_response("""
          === Content Topics ===

          #{topics}

          ---
          Generated in #{elapsed}ms
          """)

        {:error, reason} ->
          Shared.error_response("Failed to discover topics: #{Shared.sanitize_error(reason)}")
      end
    end
  end

  # === Gopher Proxy Handlers ===

  @doc """
  Fetch prompt.
  """
  def fetch_prompt(host, port) do
    [
      Shared.info_line("=== Gopher Proxy ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Fetch content from external Gopher servers.", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter a Gopher URL:", host, port),
      Shared.info_line("Format: gopher://host[:port]/selector", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Example: gopher://gopher.floodgap.com/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle fetch request.
  """
  def handle_fetch(url, _host, _port) do
    Logger.info("Fetching: #{url}")

    case GopherProxy.fetch(url) do
      {:ok, result} ->
        Shared.format_plain_text_response("""
        === Fetched from #{url} ===

        #{result.content}

        ---
        Proxied via PureGopherAI
        """)

      {:error, reason} ->
        Shared.error_response("Failed to fetch: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  Handle fetch and summarize request.
  """
  def handle_fetch_summary(url, host, port, socket) do
    Logger.info("Fetching and summarizing: #{url}")

    case GopherProxy.fetch(url) do
      {:ok, result} ->
        content = result.content
        start_time = System.monotonic_time(:millisecond)

        if socket && PureGopherAi.AiEngine.streaming_enabled?() do
          stream_summary_response(socket, content, "fetched content", url, host, port, start_time)
        else
          case Summarizer.summarize_text(content) do
            {:ok, summary} ->
              elapsed = System.monotonic_time(:millisecond) - start_time

              Shared.format_plain_text_response("""
              === Summary of #{url} ===

              #{summary}

              ---
              Generated in #{elapsed}ms
              """)

            {:error, reason} ->
              Shared.error_response("Failed to summarize: #{Shared.sanitize_error(reason)}")
          end
        end

      {:error, reason} ->
        Shared.error_response("Failed to fetch: #{Shared.sanitize_error(reason)}")
    end
  end

  # === Code Assistant Handlers ===

  @doc """
  Code assistant menu.
  """
  def code_menu(host, port) do
    [
      Shared.info_line("=== Code Assistant ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("AI-powered code help.", host, port),
      Shared.info_line("", host, port),
      Shared.search_line("Generate Code", "/code/generate", host, port),
      Shared.search_line("Explain Code", "/code/explain", host, port),
      Shared.search_line("Review Code", "/code/review", host, port),
      Shared.link_line("Supported Languages", "/code/languages", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Home", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  List supported languages.
  """
  def code_languages(host, port) do
    languages = CodeAssistant.supported_languages()

    lang_lines = languages
      |> Enum.map(fn lang -> Shared.info_line("  #{lang}", host, port) end)

    [
      Shared.info_line("=== Supported Languages ===", host, port),
      Shared.info_line("", host, port),
      lang_lines,
      Shared.info_line("", host, port),
      Shared.link_line("Back to Code", "/code", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Code generate prompt.
  """
  def code_generate_prompt(host, port) do
    [
      Shared.info_line("=== Generate Code ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Format: language | description", host, port),
      Shared.info_line("Example: python | function to calculate fibonacci", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle code generation.
  """
  def handle_code_generate(input, host, port, socket) do
    case String.split(input, "|", parts: 2) do
      [lang, description] ->
        lang = String.trim(lang)
        description = String.trim(description)

        Logger.info("Generating #{lang} code: #{description}")
        start_time = System.monotonic_time(:millisecond)

        if socket && PureGopherAi.AiEngine.streaming_enabled?() do
          stream_code_response(socket, "generate", lang, description, host, port, start_time)
        else
          case CodeAssistant.generate(lang, description) do
            {:ok, code} ->
              elapsed = System.monotonic_time(:millisecond) - start_time

              Shared.format_plain_text_response("""
              === Generated #{lang} Code ===

              #{code}

              ---
              Generated in #{elapsed}ms
              """)

            {:error, reason} ->
              Shared.error_response("Failed to generate: #{Shared.sanitize_error(reason)}")
          end
        end

      _ ->
        Shared.error_response("Invalid format. Use: language | description")
    end
  end

  @doc """
  Code explain prompt.
  """
  def code_explain_prompt(host, port) do
    [
      Shared.info_line("=== Explain Code ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Paste your code to explain:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle code explanation.
  """
  def handle_code_explain(code, host, port, socket) do
    Logger.info("Explaining code")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      stream_code_response(socket, "explain", nil, code, host, port, start_time)
    else
      case CodeAssistant.explain(code) do
        {:ok, explanation} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          Shared.format_plain_text_response("""
          === Code Explanation ===

          #{explanation}

          ---
          Generated in #{elapsed}ms
          """)

        {:error, reason} ->
          Shared.error_response("Failed to explain: #{Shared.sanitize_error(reason)}")
      end
    end
  end

  @doc """
  Code review prompt.
  """
  def code_review_prompt(host, port) do
    [
      Shared.info_line("=== Review Code ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Paste your code for review:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle code review.
  """
  def handle_code_review(code, host, port, socket) do
    Logger.info("Reviewing code")
    start_time = System.monotonic_time(:millisecond)

    if socket && PureGopherAi.AiEngine.streaming_enabled?() do
      stream_code_response(socket, "review", nil, code, host, port, start_time)
    else
      case CodeAssistant.review(code) do
        {:ok, review} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          Shared.format_plain_text_response("""
          === Code Review ===

          #{review}

          ---
          Generated in #{elapsed}ms
          """)

        {:error, reason} ->
          Shared.error_response("Failed to review: #{Shared.sanitize_error(reason)}")
      end
    end
  end

  # === Streaming Helper Functions (Plain Text for Type 0) ===

  defp stream_docs_response(socket, query, _host, _port, start_time) do
    ThousandIsland.Socket.send(socket, "Query: #{query}\r\n\r\nAnswer:\r\n")

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    case Rag.query_stream(query, fn chunk ->
           if String.length(chunk) > 0 do
             streamer.(chunk)
           end
         end) do
      {:ok, result} ->
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time

        sources = result.sources
          |> Enum.map(fn s -> "- #{s.name}" end)
          |> Enum.join("\r\n")

        footer = "\r\n\r\nSources:\r\n#{sources}\r\n---\r\nGenerated in #{elapsed}ms (streamed)\r\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\r\nError generating response.\r\n.\r\n")
    end

    :streamed
  end

  defp stream_summary_response(socket, content, content_type, title, _host, _port, start_time) do
    ThousandIsland.Socket.send(socket, "=== TL;DR: #{title} ===\r\n\r\n")

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    case Summarizer.summarize_text_stream(content, fn chunk ->
           if String.length(chunk) > 0 do
             streamer.(chunk)
           end
         end) do
      {:ok, _} ->
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time
        footer = "\r\n\r\n---\r\nType: #{content_type}\r\nGenerated in #{elapsed}ms (streamed)\r\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\r\nError generating summary.\r\n.\r\n")
    end

    :streamed
  end

  defp stream_translate_response(socket, content, lang, content_type, title, _host, _port, start_time) do
    ThousandIsland.Socket.send(socket, "=== #{title} (#{lang}) ===\r\n\r\n")

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    case Summarizer.translate_stream(content, lang, fn chunk ->
           if String.length(chunk) > 0 do
             streamer.(chunk)
           end
         end) do
      {:ok, _} ->
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time
        footer = "\r\n\r\n---\r\nType: #{content_type}\r\nTranslated in #{elapsed}ms (streamed)\r\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\r\nError translating.\r\n.\r\n")
    end

    :streamed
  end

  defp stream_digest_response(socket, _host, _port, start_time) do
    ThousandIsland.Socket.send(socket, "=== Daily Digest ===\r\n\r\n")

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    case Summarizer.daily_digest_stream(fn chunk ->
           if String.length(chunk) > 0 do
             streamer.(chunk)
           end
         end) do
      {:ok, _} ->
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time
        footer = "\r\n\r\n---\r\nGenerated in #{elapsed}ms (streamed)\r\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\r\nError generating digest.\r\n.\r\n")
    end

    :streamed
  end

  defp stream_topics_response(socket, _host, _port, start_time) do
    ThousandIsland.Socket.send(socket, "=== Content Topics ===\r\n\r\n")

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    case Summarizer.discover_topics() do
      {:ok, topics} ->
        streamer.(topics)
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time
        footer = "\r\n\r\n---\r\nGenerated in #{elapsed}ms\r\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\r\nError discovering topics.\r\n.\r\n")
    end

    :streamed
  end

  defp stream_discover_response(socket, interest, _host, _port, start_time) do
    ThousandIsland.Socket.send(socket, "=== Recommendations for \"#{interest}\" ===\r\n\r\n")

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    case Summarizer.recommend(interest) do
      {:ok, recommendations} ->
        streamer.(recommendations)
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time
        footer = "\r\n\r\n---\r\nGenerated in #{elapsed}ms\r\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\r\nError generating recommendations.\r\n.\r\n")
    end

    :streamed
  end

  defp stream_explain_response(socket, term, _host, _port, start_time) do
    ThousandIsland.Socket.send(socket, "=== #{term} ===\r\n\r\n")

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    case Summarizer.explain_stream(term, fn chunk ->
           if String.length(chunk) > 0 do
             streamer.(chunk)
           end
         end) do
      {:ok, _} ->
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time
        footer = "\r\n\r\n---\r\nGenerated in #{elapsed}ms (streamed)\r\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\r\nError explaining.\r\n.\r\n")
    end

    :streamed
  end

  defp stream_code_response(socket, action, lang, input, _host, _port, start_time) do
    header_text = case action do
      "generate" -> "=== Generated #{lang} Code ==="
      "explain" -> "=== Code Explanation ==="
      "review" -> "=== Code Review ==="
      _ -> "=== Code Assistant ==="
    end

    ThousandIsland.Socket.send(socket, "#{header_text}\r\n\r\n")

    {streamer, flush} = Shared.start_plain_buffered_streamer(socket)

    result = case action do
      "generate" -> CodeAssistant.generate_stream(lang, input, fn chunk ->
        if String.length(chunk) > 0, do: streamer.(chunk)
      end)
      "explain" -> CodeAssistant.explain_stream(input, fn chunk ->
        if String.length(chunk) > 0, do: streamer.(chunk)
      end)
      "review" -> CodeAssistant.review_stream(input, fn chunk ->
        if String.length(chunk) > 0, do: streamer.(chunk)
      end)
      _ -> {:error, :unknown_action}
    end

    case result do
      {:ok, _} ->
        flush.()
        elapsed = System.monotonic_time(:millisecond) - start_time
        footer = "\r\n\r\n---\r\nGenerated in #{elapsed}ms (streamed)\r\n.\r\n"
        ThousandIsland.Socket.send(socket, footer)

      {:error, _} ->
        flush.()
        ThousandIsland.Socket.send(socket, "\r\nError generating code.\r\n.\r\n")
    end

    :streamed
  end
end
