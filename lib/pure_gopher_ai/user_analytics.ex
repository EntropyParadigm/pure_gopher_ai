defmodule PureGopherAi.UserAnalytics do
  @moduledoc """
  User analytics and engagement statistics.

  Features:
  - Profile view tracking
  - Post engagement metrics
  - Follower growth
  - Content performance
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserProfiles
  alias PureGopherAi.UserPhlog
  alias PureGopherAi.Reactions
  alias PureGopherAi.Comments
  alias PureGopherAi.Follows

  @table_name :user_analytics
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records an event for analytics.
  """
  def record_event(event_type, username, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:record, event_type, username, metadata})
  end

  @doc """
  Gets analytics summary for a user.
  """
  def summary(username, passphrase) do
    GenServer.call(__MODULE__, {:summary, username, passphrase})
  end

  @doc """
  Gets detailed post analytics for a user.
  """
  def post_analytics(username, passphrase) do
    GenServer.call(__MODULE__, {:post_analytics, username, passphrase})
  end

  @doc """
  Gets engagement over time for a user.
  """
  def engagement_over_time(username, passphrase, opts \\ []) do
    GenServer.call(__MODULE__, {:engagement_over_time, username, passphrase, opts})
  end

  @doc """
  Gets top performing content for a user.
  """
  def top_content(username, passphrase, opts \\ []) do
    GenServer.call(__MODULE__, {:top_content, username, passphrase, opts})
  end

  @doc """
  Gets audience insights (who is engaging with content).
  """
  def audience_insights(username, passphrase) do
    GenServer.call(__MODULE__, {:audience_insights, username, passphrase})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "user_analytics.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :bag)

    Logger.info("[UserAnalytics] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, event_type, username, metadata}, state) do
    username_lower = String.downcase(String.trim(username))
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    date = Date.utc_today() |> Date.to_iso8601()

    event = %{
      type: event_type,
      username: username_lower,
      date: date,
      timestamp: now,
      metadata: metadata
    }

    :dets.insert(@table_name, {username_lower, event})
    {:noreply, state}
  end

  @impl true
  def handle_call({:summary, username, passphrase}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, profile} ->
        username_lower = String.downcase(String.trim(username))
        summary = compute_summary(username_lower, profile)
        {:reply, {:ok, summary}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:post_analytics, username, passphrase}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))
        analytics = compute_post_analytics(username_lower)
        {:reply, {:ok, analytics}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:engagement_over_time, username, passphrase, opts}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))
        days = Keyword.get(opts, :days, 30)
        engagement = compute_engagement_over_time(username_lower, days)
        {:reply, {:ok, engagement}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:top_content, username, passphrase, opts}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))
        limit = Keyword.get(opts, :limit, 10)
        metric = Keyword.get(opts, :by, :engagement)
        top = compute_top_content(username_lower, limit, metric)
        {:reply, {:ok, top}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:audience_insights, username, passphrase}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))
        insights = compute_audience_insights(username_lower)
        {:reply, {:ok, insights}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp compute_summary(username_lower, profile) do
    # Get posts
    {:ok, posts, total_posts} = UserPhlog.list_posts(username_lower, limit: 1000)

    # Calculate totals
    total_views = Enum.sum(Enum.map(posts, & &1.views))

    {total_upvotes, total_downvotes} = posts
    |> Enum.reduce({0, 0}, fn post, {up, down} ->
      score = Reactions.get_score(:phlog, post.id)
      {up + score.upvotes, down + score.downvotes}
    end)

    total_comments = posts
    |> Enum.map(fn post -> Comments.count(:phlog, post.id) end)
    |> Enum.sum()

    # Get follower counts
    follow_counts = Follows.counts(username_lower)

    %{
      profile_views: profile.views,
      total_posts: total_posts,
      total_views: total_views,
      total_upvotes: total_upvotes,
      total_downvotes: total_downvotes,
      total_comments: total_comments,
      followers: follow_counts.followers,
      following: follow_counts.following,
      engagement_rate: calculate_engagement_rate(total_views, total_upvotes + total_comments),
      avg_views_per_post: if(total_posts > 0, do: Float.round(total_views / total_posts, 1), else: 0),
      member_since: profile.created_at
    }
  end

  defp compute_post_analytics(username_lower) do
    {:ok, posts, _} = UserPhlog.list_posts(username_lower, limit: 100)

    posts
    |> Enum.map(fn post ->
      score = Reactions.get_score(:phlog, post.id)
      comment_count = Comments.count(:phlog, post.id)

      %{
        post_id: post.id,
        title: post.title,
        created_at: post.created_at,
        views: post.views,
        upvotes: score.upvotes,
        downvotes: score.downvotes,
        comments: comment_count,
        engagement_score: score.upvotes + (comment_count * 2),
        engagement_rate: calculate_engagement_rate(post.views, score.upvotes + comment_count)
      }
    end)
    |> Enum.sort_by(& &1.engagement_score, :desc)
  end

  defp compute_engagement_over_time(username_lower, days) do
    # Get events from DETS
    events = :dets.lookup(@table_name, username_lower)
      |> Enum.map(fn {_key, event} -> event end)

    # Group by date
    cutoff = Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()

    events
    |> Enum.filter(fn e -> e.date >= cutoff end)
    |> Enum.group_by(& &1.date)
    |> Enum.map(fn {date, day_events} ->
      %{
        date: date,
        views: Enum.count(day_events, &(&1.type == :view)),
        upvotes: Enum.count(day_events, &(&1.type == :upvote)),
        comments: Enum.count(day_events, &(&1.type == :comment)),
        new_followers: Enum.count(day_events, &(&1.type == :follow))
      }
    end)
    |> Enum.sort_by(& &1.date)
  end

  defp compute_top_content(username_lower, limit, metric) do
    {:ok, posts, _} = UserPhlog.list_posts(username_lower, limit: 100)

    sorted = posts
    |> Enum.map(fn post ->
      score = Reactions.get_score(:phlog, post.id)
      comment_count = Comments.count(:phlog, post.id)

      value = case metric do
        :views -> post.views
        :upvotes -> score.upvotes
        :comments -> comment_count
        :engagement -> score.upvotes + (comment_count * 2) + (post.views / 10)
        _ -> score.upvotes
      end

      %{
        post_id: post.id,
        title: post.title,
        created_at: post.created_at,
        metric_value: value,
        views: post.views,
        upvotes: score.upvotes,
        comments: comment_count
      }
    end)
    |> Enum.sort_by(& &1.metric_value, :desc)
    |> Enum.take(limit)

    %{
      metric: metric,
      posts: sorted
    }
  end

  defp compute_audience_insights(username_lower) do
    # Get followers
    {:ok, followers} = Follows.followers(username_lower, limit: 100)

    # Get recent reactors
    {:ok, posts, _} = UserPhlog.list_posts(username_lower, limit: 20)

    reactors = posts
    |> Enum.flat_map(fn post ->
      {:ok, reactions} = Reactions.user_reactions(post.id, type: :phlog)
      Enum.map(reactions, & &1.username)
    end)
    |> Enum.frequencies()

    # Get recent commenters
    commenters = posts
    |> Enum.flat_map(fn post ->
      {:ok, comments} = Comments.get_comments(:phlog, post.id, flat: true)
      Enum.map(comments, & &1.author)
    end)
    |> Enum.reject(&(&1 == username_lower))
    |> Enum.frequencies()

    %{
      follower_count: length(followers),
      recent_followers: Enum.take(followers, 10),
      top_engagers: reactors
        |> Enum.sort_by(fn {_u, c} -> -c end)
        |> Enum.take(10)
        |> Enum.map(fn {u, c} -> %{username: u, reactions: c} end),
      frequent_commenters: commenters
        |> Enum.sort_by(fn {_u, c} -> -c end)
        |> Enum.take(10)
        |> Enum.map(fn {u, c} -> %{username: u, comments: c} end)
    }
  end

  defp calculate_engagement_rate(views, engagements) when views > 0 do
    Float.round(engagements / views * 100, 2)
  end
  defp calculate_engagement_rate(_, _), do: 0.0
end
