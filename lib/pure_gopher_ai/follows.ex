defmodule PureGopherAi.Follows do
  @moduledoc """
  Follow/subscribe system for users.

  Features:
  - Follow other users
  - Get notifications when followed users post
  - View following/followers lists
  - Feed of content from followed users
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserProfiles
  alias PureGopherAi.Notifications

  @table_name :follows
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_following 500

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Follows a user.
  """
  def follow(username, passphrase, target_username) do
    GenServer.call(__MODULE__, {:follow, username, passphrase, target_username})
  end

  @doc """
  Unfollows a user.
  """
  def unfollow(username, passphrase, target_username) do
    GenServer.call(__MODULE__, {:unfollow, username, passphrase, target_username})
  end

  @doc """
  Checks if user A follows user B.
  """
  def following?(username, target_username) do
    GenServer.call(__MODULE__, {:following?, username, target_username})
  end

  @doc """
  Gets list of users that username is following.
  """
  def following(username, opts \\ []) do
    GenServer.call(__MODULE__, {:following, username, opts})
  end

  @doc """
  Gets list of users that follow username.
  """
  def followers(username, opts \\ []) do
    GenServer.call(__MODULE__, {:followers, username, opts})
  end

  @doc """
  Gets follow counts for a user.
  """
  def counts(username) do
    GenServer.call(__MODULE__, {:counts, username})
  end

  @doc """
  Notifies followers of new content from a user.
  Called by other modules when content is created.
  """
  def notify_followers(author, content_type, content_id, title) do
    GenServer.cast(__MODULE__, {:notify_followers, author, content_type, content_id, title})
  end

  @doc """
  Gets suggested users to follow based on who you follow.
  """
  def suggestions(username, opts \\ []) do
    GenServer.call(__MODULE__, {:suggestions, username, opts})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "follows.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    Logger.info("[Follows] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:follow, username, passphrase, target_username}, _from, state) do
    follower_lower = String.downcase(String.trim(username))
    target_lower = String.downcase(String.trim(target_username))

    cond do
      follower_lower == target_lower ->
        {:reply, {:error, :cannot_follow_self}, state}

      true ->
        case UserProfiles.authenticate(username, passphrase) do
          {:ok, _profile} ->
            # Check if target exists
            case UserProfiles.get(target_username) do
              {:ok, _target_profile} ->
                key = {follower_lower, target_lower}

                # Check if already following
                case :dets.lookup(@table_name, key) do
                  [{^key, _}] ->
                    {:reply, {:error, :already_following}, state}

                  [] ->
                    # Check follow limit
                    current_count = count_following(follower_lower)

                    if current_count >= @max_following do
                      {:reply, {:error, :follow_limit_reached}, state}
                    else
                      now = DateTime.utc_now() |> DateTime.to_iso8601()

                      follow_data = %{
                        follower: username,
                        follower_lower: follower_lower,
                        target: target_username,
                        target_lower: target_lower,
                        created_at: now
                      }

                      :dets.insert(@table_name, {key, follow_data})
                      :dets.sync(@table_name)

                      # Notify the target user
                      Notifications.create(
                        target_lower,
                        :follow,
                        "New follower",
                        "#{username} is now following you",
                        %{follower: username}
                      )

                      Logger.info("[Follows] #{username} followed #{target_username}")
                      {:reply, :ok, state}
                    end
                end

              {:error, :not_found} ->
                {:reply, {:error, :user_not_found}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:unfollow, username, passphrase, target_username}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        follower_lower = String.downcase(String.trim(username))
        target_lower = String.downcase(String.trim(target_username))
        key = {follower_lower, target_lower}

        case :dets.lookup(@table_name, key) do
          [{^key, _}] ->
            :dets.delete(@table_name, key)
            :dets.sync(@table_name)
            Logger.info("[Follows] #{username} unfollowed #{target_username}")
            {:reply, :ok, state}

          [] ->
            {:reply, {:error, :not_following}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:following?, username, target_username}, _from, state) do
    follower_lower = String.downcase(String.trim(username))
    target_lower = String.downcase(String.trim(target_username))
    key = {follower_lower, target_lower}

    result = case :dets.lookup(@table_name, key) do
      [{^key, _}] -> true
      [] -> false
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:following, username, opts}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    following = :dets.foldl(fn {{follower, _target}, data}, acc ->
      if follower == username_lower do
        [%{
          username: data.target,
          followed_at: data.created_at
        } | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.sort_by(& &1.followed_at, :desc)
    |> Enum.drop(offset)
    |> Enum.take(limit)

    {:reply, {:ok, following}, state}
  end

  @impl true
  def handle_call({:followers, username, opts}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    followers = :dets.foldl(fn {{_follower, target}, data}, acc ->
      if target == username_lower do
        [%{
          username: data.follower,
          followed_at: data.created_at
        } | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.sort_by(& &1.followed_at, :desc)
    |> Enum.drop(offset)
    |> Enum.take(limit)

    {:reply, {:ok, followers}, state}
  end

  @impl true
  def handle_call({:counts, username}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    {following, followers} = :dets.foldl(fn {{follower, target}, _data}, {fing, fers} ->
      cond do
        follower == username_lower -> {fing + 1, fers}
        target == username_lower -> {fing, fers + 1}
        true -> {fing, fers}
      end
    end, {0, 0}, @table_name)

    {:reply, %{following: following, followers: followers}, state}
  end

  @impl true
  def handle_call({:suggestions, username, opts}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    limit = Keyword.get(opts, :limit, 10)

    # Get who I follow
    my_following = :dets.foldl(fn {{follower, target}, _data}, acc ->
      if follower == username_lower do
        MapSet.put(acc, target)
      else
        acc
      end
    end, MapSet.new(), @table_name)

    # Get who my follows follow (second-degree connections)
    suggestions = :dets.foldl(fn {{follower, target}, _data}, acc ->
      if follower in my_following and target != username_lower and target not in my_following do
        Map.update(acc, target, 1, &(&1 + 1))
      else
        acc
      end
    end, %{}, @table_name)
    |> Enum.sort_by(fn {_user, count} -> -count end)
    |> Enum.take(limit)
    |> Enum.map(fn {user, mutual_count} ->
      %{username: user, mutual_follows: mutual_count}
    end)

    {:reply, {:ok, suggestions}, state}
  end

  @impl true
  def handle_cast({:notify_followers, author, content_type, content_id, title}, state) do
    author_lower = String.downcase(String.trim(author))

    # Find all followers
    :dets.foldl(fn {{_follower, target}, data}, _acc ->
      if target == author_lower do
        Notifications.create(
          data.follower_lower,
          :new_content,
          "New #{content_type} from #{author}",
          title,
          %{
            author: author,
            content_type: content_type,
            content_id: content_id
          }
        )
      end
      nil
    end, nil, @table_name)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp count_following(username_lower) do
    :dets.foldl(fn {{follower, _target}, _data}, acc ->
      if follower == username_lower, do: acc + 1, else: acc
    end, 0, @table_name)
  end
end
