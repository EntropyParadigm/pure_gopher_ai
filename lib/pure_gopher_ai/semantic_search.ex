defmodule PureGopherAi.SemanticSearch do
  @moduledoc """
  AI-powered semantic search using vector embeddings.

  Features:
  - Natural language queries
  - Cross-content type search (phlogs, docs, posts, comments)
  - Find similar content
  - Relevance ranking with explanations
  """

  alias PureGopherAi.Rag.Embeddings
  alias PureGopherAi.Rag.DocumentStore
  alias PureGopherAi.Phlog
  alias PureGopherAi.Guestbook
  alias PureGopherAi.AiEngine

  @content_types [:phlog, :document, :post, :guestbook, :user_phlog]
  @default_limit 10

  @doc """
  Returns available content types for search.
  """
  def content_types, do: @content_types

  @doc """
  Semantic search across all content types.
  Returns results ranked by similarity with optional explanations.
  """
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    content_types = Keyword.get(opts, :types, @content_types)
    explain = Keyword.get(opts, :explain, false)

    # Get results from each content type
    results = content_types
    |> Enum.flat_map(fn type ->
      case search_content_type(type, query, limit) do
        {:ok, items} -> items
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)

    # Optionally add explanations
    results = if explain do
      add_explanations(results, query)
    else
      results
    end

    {:ok, results}
  end

  @doc """
  Search within a specific content type.
  """
  def search_type(type, query, opts \\ []) when type in @content_types do
    limit = Keyword.get(opts, :limit, @default_limit)
    search_content_type(type, query, limit)
  end

  @doc """
  Find content similar to a given item.
  """
  def find_similar(type, id, opts \\ []) when type in @content_types do
    limit = Keyword.get(opts, :limit, @default_limit)

    # Get the source content
    case get_content(type, id) do
      {:ok, content} ->
        # Search for similar items
        case Embeddings.search(content.text, limit: limit + 1) do
          {:ok, results} ->
            # Filter out the source item and format results
            similar = results
            |> Enum.reject(fn r -> r.id == id end)
            |> Enum.take(limit)
            |> Enum.map(fn r ->
              %{
                type: detect_content_type(r),
                id: r.id,
                title: r.metadata[:title] || "Untitled",
                excerpt: String.slice(r.chunk, 0, 200),
                score: Float.round(r.similarity, 3)
              }
            end)

            {:ok, similar}

          error -> error
        end

      error -> error
    end
  end

  @doc """
  Explain why a result matched a query.
  """
  def explain_match(query, content) do
    prompt = """
    Briefly explain why this content is relevant to the query.

    Query: "#{query}"

    Content excerpt:
    ---
    #{String.slice(content, 0, 500)}
    ---

    Write 1-2 sentences explaining the connection. Be concise.
    """

    case AiEngine.generate(prompt, max_new_tokens: 100) do
      {:ok, explanation} -> {:ok, String.trim(explanation)}
      error -> error
    end
  end

  @doc """
  Cluster content by semantic similarity.
  Returns groups of related content.
  """
  def cluster_content(type, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    num_clusters = Keyword.get(opts, :clusters, 5)

    # Get content items
    case get_all_content(type, limit) do
      {:ok, [_ | _] = items} ->
        # For simplicity, use a topic-based approach
        # Group by AI-detected themes
        cluster_by_topics(items, num_clusters)

      {:ok, []} ->
        {:ok, []}

      error -> error
    end
  end

  @doc """
  Get trending topics from recent content.
  """
  def trending_topics(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    days = Keyword.get(opts, :days, 7)

    # Collect recent content
    cutoff = DateTime.utc_now()
    |> DateTime.add(-days * 24 * 60 * 60, :second)

    content = @content_types
    |> Enum.flat_map(fn type ->
      case get_recent_content(type, 20, cutoff) do
        {:ok, items} -> items
        _ -> []
      end
    end)

    if length(content) > 0 do
      extract_topics(content, limit)
    else
      {:ok, []}
    end
  end

  # Private functions

  defp search_content_type(:phlog, query, limit) do
    # Search phlog entries
    case Embeddings.search(query, limit: limit) do
      {:ok, results} ->
        items = results
        |> Enum.filter(fn r -> r.metadata[:source] == :phlog end)
        |> Enum.map(fn r ->
          %{
            type: :phlog,
            id: r.id,
            title: r.metadata[:title] || "Untitled",
            excerpt: String.slice(r.chunk, 0, 200),
            score: Float.round(r.similarity, 3),
            path: r.metadata[:path]
          }
        end)

        {:ok, items}

      error -> error
    end
  end

  defp search_content_type(:document, query, limit) do
    case Embeddings.search(query, limit: limit) do
      {:ok, results} ->
        items = results
        |> Enum.filter(fn r -> r.metadata[:source] == :document or r.metadata[:source] == nil end)
        |> Enum.map(fn r ->
          %{
            type: :document,
            id: r.id,
            title: r.metadata[:title] || r.metadata[:filename] || "Document",
            excerpt: String.slice(r.chunk, 0, 200),
            score: Float.round(r.similarity, 3)
          }
        end)

        {:ok, items}

      error -> error
    end
  end

  defp search_content_type(:post, _query, _limit) do
    # Bulletin board search not implemented yet
    {:ok, []}
  end

  defp search_content_type(:guestbook, query, limit) do
    # Search guestbook entries
    case Guestbook.list_entries(limit: limit * 2) do
      entries when is_list(entries) ->
        query_lower = String.downcase(query)
        keywords = String.split(query_lower, ~r/\s+/)

        items = entries
        |> Enum.map(fn entry ->
          text = String.downcase((entry.name || "") <> " " <> (entry.message || ""))
          score = calculate_text_score(text, keywords)
          %{
            type: :guestbook,
            id: entry.id,
            title: "From #{entry.name}",
            excerpt: String.slice(entry.message || "", 0, 200),
            score: score
          }
        end)
        |> Enum.filter(& &1.score > 0)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)

        {:ok, items}

      error -> error
    end
  end

  defp search_content_type(:user_phlog, _query, _limit) do
    # User phlog search not implemented yet
    {:ok, []}
  end

  defp search_content_type(_, _query, _limit), do: {:ok, []}

  defp calculate_text_score(text, keywords) do
    matches = Enum.count(keywords, fn kw -> String.contains?(text, kw) end)
    if length(keywords) > 0 do
      Float.round(matches / length(keywords), 3)
    else
      0.0
    end
  end

  defp get_content(:phlog, path) do
    case Phlog.get_entry(path) do
      {:ok, entry} -> {:ok, %{text: entry.content, metadata: entry}}
      error -> error
    end
  end

  defp get_content(:document, id) do
    case DocumentStore.get_document(id) do
      {:ok, doc} -> {:ok, %{text: doc.content, metadata: doc}}
      error -> error
    end
  end

  defp get_content(:post, _id) do
    {:error, :not_implemented}
  end

  defp get_content(:user_phlog, _id) do
    {:error, :not_implemented}
  end

  defp get_content(_, _), do: {:error, :unsupported_type}

  defp get_all_content(type, limit) do
    case type do
      :phlog ->
        result = Phlog.list_entries(limit: limit)
        entries = case result do
          %{entries: e} -> e
          list when is_list(list) -> list
          _ -> []
        end
        items = Enum.map(entries, fn e ->
          %{id: e.path, text: (e.title || "") <> " " <> (e.excerpt || ""), type: :phlog}
        end)
        {:ok, items}

      :document ->
        case DocumentStore.list_documents() do
          {:ok, docs} ->
            items = docs
            |> Enum.take(limit)
            |> Enum.map(fn d ->
              %{id: d.id, text: (d.title || "") <> " " <> String.slice(d.content || "", 0, 500), type: :document}
            end)
            {:ok, items}
          _ -> {:ok, []}
        end

      _ -> {:ok, []}
    end
  end

  defp get_recent_content(type, limit, _cutoff) do
    # For now, just get recent items without strict date filtering
    get_all_content(type, limit)
  end

  defp detect_content_type(result) do
    cond do
      result.metadata[:source] == :phlog -> :phlog
      result.metadata[:source] == :document -> :document
      result.metadata[:board] -> :post
      true -> :document
    end
  end

  defp add_explanations(results, query) do
    Enum.map(results, fn result ->
      case explain_match(query, result.excerpt) do
        {:ok, explanation} -> Map.put(result, :explanation, explanation)
        _ -> result
      end
    end)
  end

  defp cluster_by_topics(items, num_clusters) do
    # Use AI to extract main topics
    texts = items
    |> Enum.take(20)
    |> Enum.map(& &1.text)
    |> Enum.join("\n---\n")

    prompt = """
    Identify #{num_clusters} main topics/themes from these content excerpts.

    Content:
    ---
    #{String.slice(texts, 0, 2000)}
    ---

    List each topic on its own line, just the topic name (2-4 words).
    """

    case AiEngine.generate(prompt, max_new_tokens: 100) do
      {:ok, result} ->
        topics = result
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(num_clusters)

        # Group items by topic (simplified)
        clusters = Enum.map(topics, fn topic ->
          matching = items
          |> Enum.filter(fn item ->
            String.contains?(String.downcase(item.text), String.downcase(topic))
          end)
          |> Enum.take(5)

          %{topic: topic, items: matching}
        end)
        |> Enum.filter(fn c -> length(c.items) > 0 end)

        {:ok, clusters}

      error -> error
    end
  end

  defp extract_topics(content, limit) do
    texts = content
    |> Enum.take(30)
    |> Enum.map(& &1.text)
    |> Enum.join("\n")

    prompt = """
    What are the #{limit} trending topics/themes in this content?

    Content:
    ---
    #{String.slice(texts, 0, 2000)}
    ---

    List each topic on its own line with a brief description.
    Format: Topic - Brief description
    """

    case AiEngine.generate(prompt, max_new_tokens: 200) do
      {:ok, result} ->
        topics = result
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          case String.split(line, " - ", parts: 2) do
            [topic, desc] -> %{topic: String.trim(topic), description: String.trim(desc)}
            [topic] -> %{topic: String.trim(topic), description: ""}
          end
        end)
        |> Enum.take(limit)

        {:ok, topics}

      error -> error
    end
  end
end
