defmodule PureGopherAi.Trending do
  @moduledoc """
  Trending and popular content discovery.

  Features:
  - Trending posts (recent activity weighted)
  - All-time popular content
  - Trending tags
  - Hot discussions
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserPhlog
  alias PureGopherAi.Reactions
  alias PureGopherAi.Comments
  alias PureGopherAi.Tags

  @cache_ttl_ms 300_000  # 5 minutes

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets trending posts (combines recency with engagement).
  """
  def trending_posts(opts \\ []) do
    GenServer.call(__MODULE__, {:trending_posts, opts})
  end

  @doc """
  Gets all-time popular posts (by total score).
  """
  def popular_posts(opts \\ []) do
    GenServer.call(__MODULE__, {:popular_posts, opts})
  end

  @doc """
  Gets trending tags (most used recently).
  """
  def trending_tags(opts \\ []) do
    GenServer.call(__MODULE__, {:trending_tags, opts})
  end

  @doc """
  Gets hot discussions (most commented recently).
  """
  def hot_discussions(opts \\ []) do
    GenServer.call(__MODULE__, {:hot_discussions, opts})
  end

  @doc """
  Gets rising posts (new posts gaining traction).
  """
  def rising(opts \\ []) do
    GenServer.call(__MODULE__, {:rising, opts})
  end

  @doc """
  Gets content activity stats for a time period.
  """
  def activity_stats(opts \\ []) do
    GenServer.call(__MODULE__, {:activity_stats, opts})
  end

  @doc """
  Clears the trending cache.
  """
  def clear_cache do
    GenServer.cast(__MODULE__, :clear_cache)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(:trending_cache, [:named_table, :public, :set])

    Logger.info("[Trending] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:trending_posts, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    hours = Keyword.get(opts, :hours, 24)
    cache_key = {:trending, hours}

    result = with_cache(cache_key, fn ->
      compute_trending_posts(hours, limit * 2)
    end)

    {:reply, {:ok, Enum.take(result, limit)}, state}
  end

  @impl true
  def handle_call({:popular_posts, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    cache_key = :popular

    result = with_cache(cache_key, fn ->
      compute_popular_posts(limit * 2)
    end)

    {:reply, {:ok, Enum.take(result, limit)}, state}
  end

  @impl true
  def handle_call({:trending_tags, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    hours = Keyword.get(opts, :hours, 24)
    cache_key = {:trending_tags, hours}

    result = with_cache(cache_key, fn ->
      compute_trending_tags(hours, limit * 2)
    end)

    {:reply, {:ok, Enum.take(result, limit)}, state}
  end

  @impl true
  def handle_call({:hot_discussions, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    hours = Keyword.get(opts, :hours, 24)
    cache_key = {:hot_discussions, hours}

    result = with_cache(cache_key, fn ->
      compute_hot_discussions(hours, limit * 2)
    end)

    {:reply, {:ok, Enum.take(result, limit)}, state}
  end

  @impl true
  def handle_call({:rising, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    cache_key = :rising

    result = with_cache(cache_key, fn ->
      compute_rising(limit * 2)
    end)

    {:reply, {:ok, Enum.take(result, limit)}, state}
  end

  @impl true
  def handle_call({:activity_stats, opts}, _from, state) do
    hours = Keyword.get(opts, :hours, 24)
    cache_key = {:stats, hours}

    result = with_cache(cache_key, fn ->
      compute_activity_stats(hours)
    end)

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_cast(:clear_cache, state) do
    :ets.delete_all_objects(:trending_cache)
    {:noreply, state}
  end

  # Private functions

  defp with_cache(key, compute_fn) do
    case :ets.lookup(:trending_cache, key) do
      [{^key, result, timestamp}] ->
        if System.system_time(:millisecond) - timestamp < @cache_ttl_ms do
          result
        else
          result = compute_fn.()
          :ets.insert(:trending_cache, {key, result, System.system_time(:millisecond)})
          result
        end

      [] ->
        result = compute_fn.()
        :ets.insert(:trending_cache, {key, result, System.system_time(:millisecond)})
        result
    end
  end

  defp compute_trending_posts(hours, limit) do
    cutoff = hours_ago(hours)

    {:ok, recent_posts} = UserPhlog.recent_posts(limit: 200)

    recent_posts
    |> Enum.filter(fn post ->
      compare_dates(post.created_at, cutoff) != :lt
    end)
    |> Enum.map(fn post ->
      # Get engagement metrics
      score_data = Reactions.get_score(:phlog, post.id)
      comment_count = Comments.count(:phlog, post.id)

      # Calculate trending score (engagement / age in hours)
      age_hours = max(1, hours_since(post.created_at))
      engagement = score_data.upvotes + (comment_count * 2) + (post.views / 10)
      trending_score = engagement / :math.sqrt(age_hours)

      Map.merge(post, %{
        trending_score: trending_score,
        upvotes: score_data.upvotes,
        downvotes: score_data.downvotes,
        comment_count: comment_count
      })
    end)
    |> Enum.sort_by(& &1.trending_score, :desc)
    |> Enum.take(limit)
    |> Enum.map(&format_post/1)
  end

  defp compute_popular_posts(limit) do
    {:ok, all_posts} = UserPhlog.recent_posts(limit: 500)

    all_posts
    |> Enum.map(fn post ->
      score_data = Reactions.get_score(:phlog, post.id)
      comment_count = Comments.count(:phlog, post.id)

      total_score = score_data.score + (comment_count * 2) + (post.views / 5)

      Map.merge(post, %{
        popularity_score: total_score,
        upvotes: score_data.upvotes,
        downvotes: score_data.downvotes,
        comment_count: comment_count
      })
    end)
    |> Enum.sort_by(& &1.popularity_score, :desc)
    |> Enum.take(limit)
    |> Enum.map(&format_post/1)
  end

  defp compute_trending_tags(hours, limit) do
    cutoff = hours_ago(hours)

    {:ok, recent_posts} = UserPhlog.recent_posts(limit: 200)

    # Count tags from recent posts
    tag_counts = recent_posts
    |> Enum.filter(fn post ->
      compare_dates(post.created_at, cutoff) != :lt
    end)
    |> Enum.flat_map(fn post ->
      case Tags.get_tags(:phlog, post.id) do
        {:ok, tags} -> tags
        _ -> []
      end
    end)
    |> Enum.frequencies()

    tag_counts
    |> Enum.sort_by(fn {_tag, count} -> -count end)
    |> Enum.take(limit)
    |> Enum.map(fn {tag, count} -> %{tag: tag, count: count} end)
  end

  defp compute_hot_discussions(hours, limit) do
    cutoff = hours_ago(hours)

    {:ok, recent_comments} = Comments.recent(limit: 500)

    # Group by content and count comments
    comment_counts = recent_comments
    |> Enum.filter(fn comment ->
      compare_dates(comment.created_at, cutoff) != :lt
    end)
    |> Enum.group_by(fn c -> {c.content_type, c.content_id} end)
    |> Enum.map(fn {{type, id}, comments} ->
      %{
        content_type: type,
        content_id: id,
        recent_comments: length(comments),
        latest_activity: Enum.max_by(comments, & &1.created_at).created_at
      }
    end)
    |> Enum.sort_by(& &1.recent_comments, :desc)
    |> Enum.take(limit)

    # Enrich with content details
    Enum.map(comment_counts, fn item ->
      case item.content_type do
        :phlog ->
          # Try to get post details
          Map.put(item, :title, "Phlog Post #{item.content_id}")

        _ ->
          item
      end
    end)
  end

  defp compute_rising(limit) do
    # Posts from last 6 hours that are gaining upvotes fast
    {:ok, recent_posts} = UserPhlog.recent_posts(limit: 100)
    cutoff = hours_ago(6)

    recent_posts
    |> Enum.filter(fn post ->
      compare_dates(post.created_at, cutoff) != :lt
    end)
    |> Enum.map(fn post ->
      score_data = Reactions.get_score(:phlog, post.id)
      age_hours = max(0.5, hours_since(post.created_at))

      # Rising score = upvotes per hour
      rising_score = score_data.upvotes / age_hours

      Map.merge(post, %{
        rising_score: rising_score,
        upvotes: score_data.upvotes,
        age_hours: Float.round(age_hours, 1)
      })
    end)
    |> Enum.filter(& &1.upvotes > 0)
    |> Enum.sort_by(& &1.rising_score, :desc)
    |> Enum.take(limit)
    |> Enum.map(&format_post/1)
  end

  defp compute_activity_stats(hours) do
    cutoff = hours_ago(hours)

    {:ok, recent_posts} = UserPhlog.recent_posts(limit: 500)
    {:ok, recent_comments} = Comments.recent(limit: 500)

    new_posts = Enum.count(recent_posts, fn p ->
      compare_dates(p.created_at, cutoff) != :lt
    end)

    new_comments = Enum.count(recent_comments, fn c ->
      compare_dates(c.created_at, cutoff) != :lt
    end)

    # Count unique active users
    active_authors = recent_posts
    |> Enum.filter(fn p -> compare_dates(p.created_at, cutoff) != :lt end)
    |> Enum.map(& &1.username)
    |> Enum.uniq()
    |> length()

    active_commenters = recent_comments
    |> Enum.filter(fn c -> compare_dates(c.created_at, cutoff) != :lt end)
    |> Enum.map(& &1.author)
    |> Enum.uniq()
    |> length()

    %{
      period_hours: hours,
      new_posts: new_posts,
      new_comments: new_comments,
      active_authors: active_authors,
      active_commenters: active_commenters,
      total_active_users: active_authors + active_commenters
    }
  end

  defp format_post(post) do
    %{
      username: post.username,
      post_id: post.id,
      title: post.title,
      snippet: String.slice(post.body, 0, 150),
      created_at: post.created_at,
      views: post.views,
      upvotes: Map.get(post, :upvotes, 0),
      downvotes: Map.get(post, :downvotes, 0),
      comment_count: Map.get(post, :comment_count, 0),
      score: Map.get(post, :trending_score) || Map.get(post, :popularity_score) || Map.get(post, :rising_score, 0)
    }
  end

  defp hours_ago(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.to_iso8601()
  end

  defp hours_since(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, date, _} ->
        DateTime.diff(DateTime.utc_now(), date, :second) / 3600

      _ ->
        24  # Default to 24 hours if parse fails
    end
  end

  defp compare_dates(date_string, cutoff_string) do
    with {:ok, date, _} <- DateTime.from_iso8601(date_string),
         {:ok, cutoff, _} <- DateTime.from_iso8601(cutoff_string) do
      DateTime.compare(date, cutoff)
    else
      _ -> :lt
    end
  end
end
