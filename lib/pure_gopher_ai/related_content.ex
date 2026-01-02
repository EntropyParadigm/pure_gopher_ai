defmodule PureGopherAi.RelatedContent do
  @moduledoc """
  AI-powered related content recommendations.

  Features:
  - Find similar posts based on content
  - Tag-based recommendations
  - "You might also like" suggestions
  - Caching for performance
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserPhlog
  alias PureGopherAi.Tags
  alias PureGopherAi.Reactions
  alias PureGopherAi.AiEngine

  @cache_ttl_ms 3_600_000  # 1 hour

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets related posts for a given post.
  Uses a combination of tags, author, and content similarity.
  """
  def related_posts(username, post_id, opts \\ []) do
    GenServer.call(__MODULE__, {:related_posts, username, post_id, opts}, 30_000)
  end

  @doc """
  Gets personalized recommendations for a user based on their history.
  """
  def recommendations_for_user(username, opts \\ []) do
    GenServer.call(__MODULE__, {:recommendations, username, opts}, 30_000)
  end

  @doc """
  Gets AI-powered "more like this" suggestions.
  """
  def more_like_this(content_type, content_id, opts \\ []) do
    GenServer.call(__MODULE__, {:more_like_this, content_type, content_id, opts}, 60_000)
  end

  @doc """
  Clears the recommendation cache.
  """
  def clear_cache do
    GenServer.cast(__MODULE__, :clear_cache)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # ETS cache for recommendations
    :ets.new(:related_cache, [:named_table, :public, :set])

    Logger.info("[RelatedContent] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:related_posts, username, post_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 5)
    cache_key = {:related, username, post_id}

    # Check cache
    case get_cached(cache_key) do
      {:ok, cached} ->
        {:reply, {:ok, Enum.take(cached, limit)}, state}

      :miss ->
        # Get the source post
        case UserPhlog.get_post(username, post_id) do
          {:ok, post} ->
            related = find_related_posts(post, username, limit * 2)
            cache_result(cache_key, related)
            {:reply, {:ok, Enum.take(related, limit)}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:recommendations, username, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    cache_key = {:recommendations, username}

    case get_cached(cache_key) do
      {:ok, cached} ->
        {:reply, {:ok, Enum.take(cached, limit)}, state}

      :miss ->
        recommendations = build_user_recommendations(username, limit * 2)
        cache_result(cache_key, recommendations)
        {:reply, {:ok, Enum.take(recommendations, limit)}, state}
    end
  end

  @impl true
  def handle_call({:more_like_this, content_type, content_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 5)
    use_ai = Keyword.get(opts, :use_ai, true)
    cache_key = {:more_like_this, content_type, content_id}

    case get_cached(cache_key) do
      {:ok, cached} ->
        {:reply, {:ok, Enum.take(cached, limit)}, state}

      :miss ->
        results = if use_ai do
          find_similar_with_ai(content_type, content_id, limit * 2)
        else
          find_similar_by_tags(content_type, content_id, limit * 2)
        end

        cache_result(cache_key, results)
        {:reply, {:ok, Enum.take(results, limit)}, state}
    end
  end

  @impl true
  def handle_cast(:clear_cache, state) do
    :ets.delete_all_objects(:related_cache)
    {:noreply, state}
  end

  # Private functions

  defp get_cached(key) do
    case :ets.lookup(:related_cache, key) do
      [{^key, result, timestamp}] ->
        if System.system_time(:millisecond) - timestamp < @cache_ttl_ms do
          {:ok, result}
        else
          :ets.delete(:related_cache, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_result(key, result) do
    :ets.insert(:related_cache, {key, result, System.system_time(:millisecond)})
  end

  defp find_related_posts(source_post, source_username, limit) do
    # Get tags for source post
    {:ok, source_tags} = Tags.get_tags(:phlog, source_post.id)

    # Extract keywords from title
    title_keywords = extract_keywords(source_post.title)

    # Get all recent posts
    {:ok, recent_posts} = UserPhlog.recent_posts(limit: 100)

    # Score and rank
    recent_posts
    |> Enum.reject(fn p ->
      # Exclude the source post
      p.id == source_post.id and p.username == source_username
    end)
    |> Enum.map(fn post ->
      score = compute_similarity_score(post, source_tags, title_keywords, source_username)
      Map.put(post, :relevance_score, score)
    end)
    |> Enum.filter(fn p -> p.relevance_score > 0 end)
    |> Enum.sort_by(& &1.relevance_score, :desc)
    |> Enum.take(limit)
    |> Enum.map(&format_recommendation/1)
  end

  defp compute_similarity_score(post, source_tags, title_keywords, source_username) do
    # Get tags for this post
    {:ok, post_tags} = Tags.get_tags(:phlog, post.id)

    # Tag overlap score (0-10)
    common_tags = MapSet.intersection(MapSet.new(source_tags), MapSet.new(post_tags))
    tag_score = min(10, MapSet.size(common_tags) * 3)

    # Title keyword overlap (0-5)
    post_keywords = extract_keywords(post.title)
    common_keywords = MapSet.intersection(MapSet.new(title_keywords), MapSet.new(post_keywords))
    keyword_score = min(5, MapSet.size(common_keywords) * 2)

    # Same author bonus (2 points)
    author_score = if String.downcase(post.username) == String.downcase(source_username), do: 2, else: 0

    # Reaction score bonus (0-3)
    reaction_data = Reactions.get_score(:phlog, post.id)
    reaction_score = min(3, div(reaction_data.upvotes, 2))

    tag_score + keyword_score + author_score + reaction_score
  end

  defp extract_keywords(text) do
    # Simple keyword extraction - split and filter stopwords
    stopwords = ~w(the a an is are was were be been being have has had do does did will would could should may might must shall can)

    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in stopwords))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp build_user_recommendations(username, limit) do
    username_lower = String.downcase(String.trim(username))

    # Get user's reactions to find preferences
    {:ok, user_reactions} = Reactions.user_reactions(username, limit: 50, type: :phlog)

    upvoted_ids = user_reactions
      |> Enum.filter(&(&1.reaction == :upvote))
      |> Enum.map(& &1.content_id)

    # Get tags from upvoted content
    preferred_tags = upvoted_ids
      |> Enum.flat_map(fn id ->
        case Tags.get_tags(:phlog, id) do
          {:ok, tags} -> tags
          _ -> []
        end
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_tag, count} -> -count end)
      |> Enum.take(10)
      |> Enum.map(fn {tag, _count} -> tag end)

    # Find posts with those tags that user hasn't seen
    {:ok, recent_posts} = UserPhlog.recent_posts(limit: 200)

    recent_posts
    |> Enum.reject(fn p ->
      # Exclude user's own posts and already reacted
      String.downcase(p.username) == username_lower or
        p.id in upvoted_ids
    end)
    |> Enum.map(fn post ->
      {:ok, post_tags} = Tags.get_tags(:phlog, post.id)
      common = MapSet.intersection(MapSet.new(preferred_tags), MapSet.new(post_tags))
      score = MapSet.size(common)
      Map.put(post, :relevance_score, score)
    end)
    |> Enum.filter(fn p -> p.relevance_score > 0 end)
    |> Enum.sort_by(& &1.relevance_score, :desc)
    |> Enum.take(limit)
    |> Enum.map(&format_recommendation/1)
  end

  defp find_similar_with_ai(content_type, content_id, limit) do
    # Get content text
    content_text = case content_type do
      :phlog ->
        # Parse username and post_id from content_id (format: "username/post_id")
        case String.split(to_string(content_id), "/", parts: 2) do
          [username, post_id] ->
            case UserPhlog.get_post(username, post_id) do
              {:ok, post} -> "#{post.title}\n#{String.slice(post.body, 0, 500)}"
              _ -> nil
            end
          _ -> nil
        end

      _ -> nil
    end

    if content_text do
      # Use AI to extract themes
      prompt = """
      Extract 3-5 key themes or topics from this content as comma-separated keywords:

      #{content_text}

      Reply with ONLY the keywords, nothing else.
      """

      case AiEngine.generate(prompt, max_tokens: 50) do
        {:ok, keywords_text} ->
          keywords = keywords_text
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.map(&String.downcase/1)

          find_by_keywords(content_type, content_id, keywords, limit)

        _ ->
          find_similar_by_tags(content_type, content_id, limit)
      end
    else
      find_similar_by_tags(content_type, content_id, limit)
    end
  end

  defp find_by_keywords(_content_type, exclude_id, keywords, limit) do
    {:ok, recent_posts} = UserPhlog.recent_posts(limit: 100)

    recent_posts
    |> Enum.reject(fn p -> p.id == exclude_id end)
    |> Enum.map(fn post ->
      text = "#{post.title} #{post.body}" |> String.downcase()
      matches = Enum.count(keywords, &String.contains?(text, &1))
      Map.put(post, :relevance_score, matches)
    end)
    |> Enum.filter(fn p -> p.relevance_score > 0 end)
    |> Enum.sort_by(& &1.relevance_score, :desc)
    |> Enum.take(limit)
    |> Enum.map(&format_recommendation/1)
  end

  defp find_similar_by_tags(content_type, content_id, limit) do
    {:ok, source_tags} = Tags.get_tags(content_type, content_id)

    if source_tags == [] do
      []
    else
      # Get content with matching tags
      source_tags
      |> Enum.flat_map(fn tag ->
        case Tags.get_by_tag(tag, type: content_type, limit: 20) do
          {:ok, results} -> results
          _ -> []
        end
      end)
      |> Enum.reject(&(&1.content_id == content_id))
      |> Enum.frequencies_by(& &1.content_id)
      |> Enum.sort_by(fn {_id, count} -> -count end)
      |> Enum.take(limit)
      |> Enum.map(fn {id, score} ->
        %{content_id: id, content_type: content_type, relevance_score: score}
      end)
    end
  end

  defp format_recommendation(post) do
    %{
      username: post.username,
      post_id: post.id,
      title: post.title,
      snippet: String.slice(post.body, 0, 150),
      created_at: post.created_at,
      relevance_score: Map.get(post, :relevance_score, 0)
    }
  end
end
