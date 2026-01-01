defmodule PureGopherAi.UserPhlog do
  @moduledoc """
  User-submitted phlog (blog) posts.

  Features:
  - Users can write their own blog posts
  - Passphrase authentication required
  - AI content moderation for illegal content
  - Rate limiting (1 post per hour)
  - Content limits (title 100 chars, body 10,000 chars)
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserProfiles
  alias PureGopherAi.ContentModerator
  alias PureGopherAi.InputSanitizer

  @table_name :user_phlog
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_title_length 100
  @max_body_length 10_000
  @max_posts_per_user 100
  @post_cooldown_ms 3_600_000  # 1 hour

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new phlog post. Requires passphrase authentication.
  """
  def create_post(username, passphrase, title, body, ip \\ nil) do
    GenServer.call(__MODULE__, {:create, username, passphrase, title, body, ip}, 30_000)
  end

  @doc """
  Lists all posts by a user (public, no auth required).
  """
  def list_posts(username, opts \\ []) do
    GenServer.call(__MODULE__, {:list, username, opts})
  end

  @doc """
  Gets a specific post by ID (public, no auth required).
  """
  def get_post(username, post_id) do
    GenServer.call(__MODULE__, {:get, username, post_id})
  end

  @doc """
  Edits an existing post. Requires passphrase authentication.
  """
  def edit_post(username, passphrase, post_id, title, body, ip \\ nil) do
    GenServer.call(__MODULE__, {:edit, username, passphrase, post_id, title, body, ip}, 30_000)
  end

  @doc """
  Deletes a post. Requires passphrase authentication.
  """
  def delete_post(username, passphrase, post_id) do
    GenServer.call(__MODULE__, {:delete, username, passphrase, post_id})
  end

  @doc """
  Lists all users who have phlog posts.
  """
  def list_authors(opts \\ []) do
    GenServer.call(__MODULE__, {:authors, opts})
  end

  @doc """
  Gets recent posts across all users.
  """
  def recent_posts(opts \\ []) do
    GenServer.call(__MODULE__, {:recent, opts})
  end

  @doc """
  Gets phlog statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "user_phlog.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # ETS for post cooldowns
    :ets.new(:phlog_cooldowns, [:named_table, :public, :set])

    Logger.info("[UserPhlog] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, username, passphrase, title, body, ip}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    # Authenticate user
    case UserProfiles.authenticate(username, passphrase, ip) do
      {:ok, _profile} ->
        # Check rate limit
        if post_rate_limited?(username_lower) do
          {:reply, {:error, :rate_limited}, state}
        else
          # Validate content
          case validate_post(title, body) do
            {:ok, clean_title, clean_body} ->
              # Content moderation
              case ContentModerator.moderate(clean_title <> "\n\n" <> clean_body, :phlog_post) do
                {:ok, :approved} ->
                  post_id = generate_id()
                  now = DateTime.utc_now() |> DateTime.to_iso8601()

                  post = %{
                    id: post_id,
                    username: username,
                    username_lower: username_lower,
                    title: clean_title,
                    body: clean_body,
                    created_at: now,
                    updated_at: now,
                    views: 0
                  }

                  # Get existing posts for user
                  posts = get_user_posts(username_lower)

                  if length(posts) >= @max_posts_per_user do
                    {:reply, {:error, :post_limit_reached}, state}
                  else
                    # Store post
                    :dets.insert(@table_name, {{username_lower, post_id}, post})
                    :dets.sync(@table_name)

                    # Update cooldown
                    :ets.insert(:phlog_cooldowns, {username_lower, System.system_time(:millisecond)})

                    Logger.info("[UserPhlog] Post created: #{username}/#{post_id}")
                    {:reply, {:ok, post}, state}
                  end

                {:error, :blocked, reason} ->
                  {:reply, {:error, :content_blocked, reason}, state}
              end

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:list, username, opts}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    posts = get_user_posts(username_lower)
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:reply, {:ok, posts, length(get_user_posts(username_lower))}, state}
  end

  @impl true
  def handle_call({:get, username, post_id}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, {username_lower, post_id}) do
      [{{^username_lower, ^post_id}, post}] ->
        # Increment view count
        updated = %{post | views: post.views + 1}
        :dets.insert(@table_name, {{username_lower, post_id}, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:edit, username, passphrase, post_id, title, body, ip}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    # Authenticate user
    case UserProfiles.authenticate(username, passphrase, ip) do
      {:ok, _profile} ->
        case :dets.lookup(@table_name, {username_lower, post_id}) do
          [{{^username_lower, ^post_id}, post}] ->
            # Validate content
            case validate_post(title, body) do
              {:ok, clean_title, clean_body} ->
                # Content moderation
                case ContentModerator.moderate(clean_title <> "\n\n" <> clean_body, :phlog_post) do
                  {:ok, :approved} ->
                    updated = %{post |
                      title: clean_title,
                      body: clean_body,
                      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
                    }

                    :dets.insert(@table_name, {{username_lower, post_id}, updated})
                    :dets.sync(@table_name)

                    Logger.info("[UserPhlog] Post edited: #{username}/#{post_id}")
                    {:reply, {:ok, updated}, state}

                  {:error, :blocked, reason} ->
                    {:reply, {:error, :content_blocked, reason}, state}
                end

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          [] ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete, username, passphrase, post_id}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    # Authenticate user
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        case :dets.lookup(@table_name, {username_lower, post_id}) do
          [{{^username_lower, ^post_id}, _post}] ->
            :dets.delete(@table_name, {username_lower, post_id})
            :dets.sync(@table_name)

            Logger.info("[UserPhlog] Post deleted: #{username}/#{post_id}")
            {:reply, :ok, state}

          [] ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:authors, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)

    authors = :dets.foldl(fn {{username_lower, _post_id}, post}, acc ->
      Map.update(acc, username_lower, %{username: post.username, count: 1, latest: post.created_at}, fn existing ->
        %{existing |
          count: existing.count + 1,
          latest: max(existing.latest, post.created_at)
        }
      end)
    end, %{}, @table_name)

    sorted = authors
      |> Map.values()
      |> Enum.sort_by(& &1.latest, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:recent, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)

    posts = :dets.foldl(fn {_key, post}, acc ->
      [post | acc]
    end, [], @table_name)
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, posts}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {total_posts, total_authors, total_views} = :dets.foldl(fn {{username_lower, _}, post}, {posts, authors, views} ->
      {posts + 1, MapSet.put(authors, username_lower), views + post.views}
    end, {0, MapSet.new(), 0}, @table_name)

    {:reply, %{
      total_posts: total_posts,
      total_authors: MapSet.size(total_authors),
      total_views: total_views
    }, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp get_user_posts(username_lower) do
    :dets.foldl(fn
      {{^username_lower, _post_id}, post}, acc -> [post | acc]
      _, acc -> acc
    end, [], @table_name)
  end

  defp post_rate_limited?(username_lower) do
    now = System.system_time(:millisecond)

    case :ets.lookup(:phlog_cooldowns, username_lower) do
      [{^username_lower, last_post}] when now - last_post < @post_cooldown_ms ->
        true
      _ ->
        false
    end
  end

  defp validate_post(title, body) do
    title = String.trim(title || "")
    body = String.trim(body || "")

    cond do
      title == "" ->
        {:error, :empty_title}

      String.length(title) > @max_title_length ->
        {:error, :title_too_long}

      body == "" ->
        {:error, :empty_body}

      String.length(body) > @max_body_length ->
        {:error, :body_too_long}

      true ->
        # Sanitize content
        clean_title = sanitize_text(title)
        clean_body = sanitize_text(body)
        {:ok, clean_title, clean_body}
    end
  end

  defp sanitize_text(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")  # Strip HTML tags
    |> then(&InputSanitizer.sanitize(&1, allow_newlines: true))
  end
end
