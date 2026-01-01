defmodule PureGopherAi.Summarizer do
  @moduledoc """
  AI-powered content summarization for PureGopherAI.

  Provides summarization capabilities for:
  - Phlog entries (TL;DR)
  - RAG documents
  - External Gopher content
  - Search results
  - Daily digests and topic discovery
  """

  require Logger

  alias PureGopherAi.AiEngine
  alias PureGopherAi.Phlog
  alias PureGopherAi.Rag

  @doc """
  Summarizes a phlog entry by path.
  Returns a concise TL;DR of the blog post.
  """
  def summarize_phlog(entry_path, opts \\ []) do
    max_words = Keyword.get(opts, :max_words, 100)

    case Phlog.get_entry(entry_path) do
      {:ok, entry} ->
        prompt = build_summary_prompt(entry.content, max_words, "blog post")

        case AiEngine.generate(prompt) do
          {:ok, summary} -> {:ok, %{title: entry.title, date: entry.date, summary: summary}}
          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Summarizes a phlog entry with streaming output.
  """
  def summarize_phlog_stream(entry_path, callback, opts \\ []) do
    max_words = Keyword.get(opts, :max_words, 100)

    case Phlog.get_entry(entry_path) do
      {:ok, entry} ->
        prompt = build_summary_prompt(entry.content, max_words, "blog post")
        AiEngine.generate_stream(prompt, nil, callback)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Summarizes a RAG document by ID.
  Generates an overview of the document content.
  """
  def summarize_document(doc_id, opts \\ []) do
    max_words = Keyword.get(opts, :max_words, 150)

    case Rag.get_document(doc_id) do
      {:ok, doc} ->
        # Get all chunks and combine
        chunks = PureGopherAi.Rag.DocumentStore.get_chunks(doc_id)
        content = chunks
          |> Enum.map(& &1.content)
          |> Enum.join("\n\n")
          |> String.slice(0, 8000)  # Limit input size

        prompt = build_summary_prompt(content, max_words, "document")

        case AiEngine.generate(prompt) do
          {:ok, summary} -> {:ok, %{filename: doc.filename, summary: summary}}
          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Summarizes a RAG document with streaming output.
  """
  def summarize_document_stream(doc_id, callback, opts \\ []) do
    max_words = Keyword.get(opts, :max_words, 150)

    case Rag.get_document(doc_id) do
      {:ok, _doc} ->
        chunks = PureGopherAi.Rag.DocumentStore.get_chunks(doc_id)
        content = chunks
          |> Enum.map(& &1.content)
          |> Enum.join("\n\n")
          |> String.slice(0, 8000)

        prompt = build_summary_prompt(content, max_words, "document")
        AiEngine.generate_stream(prompt, nil, callback)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Summarizes arbitrary text content.
  """
  def summarize_text(text, opts \\ []) do
    max_words = Keyword.get(opts, :max_words, 100)
    content_type = Keyword.get(opts, :type, "content")

    prompt = build_summary_prompt(text, max_words, content_type)
    AiEngine.generate(prompt)
  end

  @doc """
  Summarizes text with streaming output.
  """
  def summarize_text_stream(text, callback, opts \\ []) do
    max_words = Keyword.get(opts, :max_words, 100)
    content_type = Keyword.get(opts, :type, "content")

    prompt = build_summary_prompt(text, max_words, content_type)
    AiEngine.generate_stream(prompt, nil, callback)
  end

  @doc """
  Generates a daily digest of recent phlog activity.
  Summarizes the most recent entries.
  """
  def daily_digest(opts \\ []) do
    entry_count = Keyword.get(opts, :entries, 5)

    result = Phlog.list_entries(page: 1, per_page: entry_count)
    entries = result.entries

    if entries == [] do
      {:ok, "No recent phlog entries to summarize."}
    else
      # Build combined content from recent entries
      content = entries
        |> Enum.map(fn {date, title, path} ->
          case Phlog.get_entry(path) do
            {:ok, entry} -> "## #{title} (#{date})\n#{String.slice(entry.content, 0, 500)}"
            _ -> "## #{title} (#{date})"
          end
        end)
        |> Enum.join("\n\n---\n\n")

      prompt = """
      Create a brief daily digest summarizing these recent blog posts.
      Highlight key themes and interesting points. Keep it concise (2-3 paragraphs).

      Recent Posts:
      #{content}

      Daily Digest:
      """

      AiEngine.generate(prompt)
    end
  end

  @doc """
  Generates a daily digest with streaming output.
  """
  def daily_digest_stream(callback, opts \\ []) do
    entry_count = Keyword.get(opts, :entries, 5)

    result = Phlog.list_entries(page: 1, per_page: entry_count)
    entries = result.entries

    if entries == [] do
      callback.("No recent phlog entries to summarize.")
      {:ok, "No recent phlog entries to summarize."}
    else
      content = entries
        |> Enum.map(fn {date, title, path} ->
          case Phlog.get_entry(path) do
            {:ok, entry} -> "## #{title} (#{date})\n#{String.slice(entry.content, 0, 500)}"
            _ -> "## #{title} (#{date})"
          end
        end)
        |> Enum.join("\n\n---\n\n")

      prompt = """
      Create a brief daily digest summarizing these recent blog posts.
      Highlight key themes and interesting points. Keep it concise (2-3 paragraphs).

      Recent Posts:
      #{content}

      Daily Digest:
      """

      AiEngine.generate_stream(prompt, nil, callback)
    end
  end

  @doc """
  Discovers and extracts topics from all content.
  Returns AI-identified themes and categories.
  """
  def discover_topics(opts \\ []) do
    # Gather content from phlog and documents
    phlog_content = gather_phlog_content(Keyword.get(opts, :phlog_count, 10))
    doc_content = gather_document_content(Keyword.get(opts, :doc_count, 5))

    combined = """
    BLOG POSTS:
    #{phlog_content}

    DOCUMENTS:
    #{doc_content}
    """

    prompt = """
    Analyze this content and identify the main topics and themes.
    List 5-10 key topics with brief descriptions.
    Format as a bulleted list.

    Content:
    #{String.slice(combined, 0, 6000)}

    Topics and Themes:
    """

    AiEngine.generate(prompt)
  end

  @doc """
  Generates content recommendations based on a query or interest.
  """
  def recommend(interest, _opts \\ []) do
    # Search across phlog and docs
    phlog_results = search_phlog_content(interest)
    doc_results = search_document_content(interest)

    if phlog_results == [] and doc_results == [] do
      {:ok, "No content found matching your interest: #{interest}"}
    else
      content_summary = build_content_summary(phlog_results, doc_results)

      prompt = """
      Based on the user's interest in "#{interest}", recommend relevant content from this server.
      Explain why each recommendation might be interesting.
      Be specific about what they'll find.

      Available Content:
      #{content_summary}

      Recommendations:
      """

      AiEngine.generate(prompt)
    end
  end

  @doc """
  Explains a technical term or concept using AI.
  """
  def explain(term, opts \\ []) do
    context = Keyword.get(opts, :context, nil)

    prompt = if context do
      """
      Explain the term "#{term}" in the context of: #{context}
      Keep the explanation clear and concise (2-3 sentences).
      """
    else
      """
      Explain the term "#{term}" clearly and concisely.
      Keep the explanation to 2-3 sentences suitable for a technical audience.
      """
    end

    AiEngine.generate(prompt)
  end

  @doc """
  Explains a term with streaming output.
  """
  def explain_stream(term, callback, opts \\ []) do
    context = Keyword.get(opts, :context, nil)

    prompt = if context do
      """
      Explain the term "#{term}" in the context of: #{context}
      Keep the explanation clear and concise (2-3 sentences).
      """
    else
      """
      Explain the term "#{term}" clearly and concisely.
      Keep the explanation to 2-3 sentences suitable for a technical audience.
      """
    end

    AiEngine.generate_stream(prompt, nil, callback)
  end

  @doc """
  Translates content to a target language using AI.
  """
  def translate(text, target_language, opts \\ []) do
    preserve_formatting = Keyword.get(opts, :preserve_formatting, true)

    prompt = build_translation_prompt(text, target_language, preserve_formatting)
    AiEngine.generate(prompt)
  end

  @doc """
  Translates content with streaming output.
  """
  def translate_stream(text, target_language, callback, opts \\ []) do
    preserve_formatting = Keyword.get(opts, :preserve_formatting, true)

    prompt = build_translation_prompt(text, target_language, preserve_formatting)
    AiEngine.generate_stream(prompt, nil, callback)
  end

  @doc """
  Translates a phlog entry to a target language.
  """
  def translate_phlog(entry_path, target_language, opts \\ []) do
    case Phlog.get_entry(entry_path) do
      {:ok, entry} ->
        case translate(entry.content, target_language, opts) do
          {:ok, translated} ->
            {:ok, %{
              title: entry.title,
              date: entry.date,
              original_content: entry.content,
              translated_content: translated,
              target_language: target_language
            }}

          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Translates a phlog entry with streaming output.
  """
  def translate_phlog_stream(entry_path, target_language, callback, opts \\ []) do
    case Phlog.get_entry(entry_path) do
      {:ok, entry} ->
        translate_stream(entry.content, target_language, callback, opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Translates a RAG document to a target language.
  """
  def translate_document(doc_id, target_language, opts \\ []) do
    case Rag.get_document(doc_id) do
      {:ok, doc} ->
        chunks = PureGopherAi.Rag.DocumentStore.get_chunks(doc_id)
        content = chunks
          |> Enum.map(& &1.content)
          |> Enum.join("\n\n")
          |> String.slice(0, 6000)  # Limit for translation

        case translate(content, target_language, opts) do
          {:ok, translated} ->
            {:ok, %{
              filename: doc.filename,
              translated_content: translated,
              target_language: target_language
            }}

          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Lists supported languages for translation.
  """
  def supported_languages do
    [
      {"en", "English"},
      {"es", "Spanish"},
      {"fr", "French"},
      {"de", "German"},
      {"it", "Italian"},
      {"pt", "Portuguese"},
      {"ja", "Japanese"},
      {"ko", "Korean"},
      {"zh", "Chinese (Simplified)"},
      {"ru", "Russian"},
      {"ar", "Arabic"},
      {"hi", "Hindi"},
      {"nl", "Dutch"},
      {"pl", "Polish"},
      {"tr", "Turkish"},
      {"vi", "Vietnamese"},
      {"th", "Thai"},
      {"sv", "Swedish"},
      {"da", "Danish"},
      {"fi", "Finnish"},
      {"no", "Norwegian"},
      {"el", "Greek"},
      {"he", "Hebrew"},
      {"uk", "Ukrainian"},
      {"cs", "Czech"}
    ]
  end

  @doc """
  Gets the full language name from a language code.
  """
  def language_name(code) do
    case Enum.find(supported_languages(), fn {c, _name} -> c == code end) do
      {_code, name} -> name
      nil -> code  # Return code if not found
    end
  end

  # Private functions

  defp build_translation_prompt(text, target_language, preserve_formatting) do
    lang_name = language_name(target_language)

    formatting_instruction = if preserve_formatting do
      "Preserve the original formatting, paragraph breaks, and structure."
    else
      "You may adjust formatting for natural flow in the target language."
    end

    """
    Translate the following text to #{lang_name}.
    #{formatting_instruction}
    Maintain the original meaning and tone.
    Only output the translation, no explanations.

    Text to translate:
    #{String.slice(text, 0, 6000)}

    Translation:
    """
  end

  defp build_summary_prompt(content, max_words, content_type) do
    """
    Summarize this #{content_type} in approximately #{max_words} words.
    Focus on the key points and main ideas.
    Be concise and informative.

    Content:
    #{String.slice(content, 0, 6000)}

    Summary:
    """
  end

  defp gather_phlog_content(count) do
    result = Phlog.list_entries(page: 1, per_page: count)

    result.entries
    |> Enum.map(fn {date, title, path} ->
      case Phlog.get_entry(path) do
        {:ok, entry} -> "- #{title} (#{date}): #{String.slice(entry.content, 0, 200)}..."
        _ -> "- #{title} (#{date})"
      end
    end)
    |> Enum.join("\n")
  end

  defp gather_document_content(count) do
    Rag.list_documents()
    |> Enum.take(count)
    |> Enum.map(fn doc ->
      chunks = PureGopherAi.Rag.DocumentStore.get_chunks(doc.id)
      preview = chunks
        |> Enum.take(1)
        |> Enum.map(& &1.content)
        |> Enum.join("")
        |> String.slice(0, 200)

      "- #{doc.filename}: #{preview}..."
    end)
    |> Enum.join("\n")
  end

  defp search_phlog_content(query) do
    result = Phlog.list_entries(page: 1, per_page: 20)
    query_lower = String.downcase(query)

    result.entries
    |> Enum.filter(fn {_date, title, path} ->
      title_match = String.contains?(String.downcase(title), query_lower)

      content_match = case Phlog.get_entry(path) do
        {:ok, entry} -> String.contains?(String.downcase(entry.content), query_lower)
        _ -> false
      end

      title_match or content_match
    end)
    |> Enum.take(5)
  end

  defp search_document_content(query) do
    case Rag.search(query, top_k: 5) do
      {:ok, results} -> results
      _ -> []
    end
  end

  defp build_content_summary(phlog_results, doc_results) do
    phlog_section = if phlog_results != [] do
      phlog_lines = Enum.map(phlog_results, fn {date, title, _path} ->
        "- Blog: #{title} (#{date})"
      end)
      "Blog Posts:\n" <> Enum.join(phlog_lines, "\n")
    else
      ""
    end

    doc_section = if doc_results != [] do
      doc_lines = Enum.map(doc_results, fn %{document: doc, chunk: chunk} ->
        preview = String.slice(chunk.content, 0, 100)
        "- Document: #{doc.filename} - #{preview}..."
      end)
      "Documents:\n" <> Enum.join(doc_lines, "\n")
    else
      ""
    end

    [phlog_section, doc_section]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end
end
