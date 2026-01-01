defmodule PureGopherAi.ScheduledPosts do
  @moduledoc """
  Scheduled post system for user phlogs.

  Allows users to schedule posts for future publication.
  Posts are automatically published when their scheduled time arrives.
  """

  use GenServer
  require Logger

  @table :scheduled_posts
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_scheduled_per_user 10
  @check_interval_ms 60_000  # Check every minute
  @min_schedule_ahead_minutes 5

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedules a phlog post for future publication.
  """
  def schedule(username, title, body, scheduled_at, opts \\ []) do
    GenServer.call(__MODULE__, {:schedule, username, title, body, scheduled_at, opts})
  end

  @doc """
  Gets scheduled posts for a user.
  """
  def list(username) do
    GenServer.call(__MODULE__, {:list, username})
  end

  @doc """
  Gets a specific scheduled post.
  """
  def get(post_id) do
    GenServer.call(__MODULE__, {:get, post_id})
  end

  @doc """
  Cancels a scheduled post.
  """
  def cancel(username, post_id) do
    GenServer.call(__MODULE__, {:cancel, username, post_id})
  end

  @doc """
  Updates a scheduled post.
  """
  def update(username, post_id, updates) do
    GenServer.call(__MODULE__, {:update, username, post_id, updates})
  end

  @doc """
  Reschedules a post to a new time.
  """
  def reschedule(username, post_id, new_scheduled_at) do
    GenServer.call(__MODULE__, {:reschedule, username, post_id, new_scheduled_at})
  end

  @doc """
  Gets statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "scheduled_posts.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: dets_file, type: :set)

    # Start the scheduler loop
    schedule_check()

    Logger.info("[ScheduledPosts] Started")
    {:ok, %{counter: get_counter()}}
  end

  @impl true
  def handle_call({:schedule, username, title, body, scheduled_at, opts}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    cond do
      # Validate title
      String.length(title) < 1 ->
        {:reply, {:error, :empty_title}, state}

      String.length(title) > 200 ->
        {:reply, {:error, :title_too_long}, state}

      # Validate body
      String.length(body) < 1 ->
        {:reply, {:error, :empty_body}, state}

      String.length(body) > 50_000 ->
        {:reply, {:error, :body_too_long}, state}

      # Validate schedule time
      not valid_schedule_time?(scheduled_at) ->
        {:reply, {:error, :invalid_schedule_time}, state}

      # Check user limit
      user_count(username_lower) >= @max_scheduled_per_user ->
        {:reply, {:error, :schedule_limit_reached}, state}

      true ->
        post_id = state.counter

        post = %{
          id: post_id,
          username: username_lower,
          title: title,
          body: body,
          scheduled_at: format_datetime(scheduled_at),
          status: :pending,
          tags: Keyword.get(opts, :tags, []),
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          published_at: nil,
          error: nil
        }

        :dets.insert(@table, {post_id, post})

        Logger.info("[ScheduledPosts] Post ##{post_id} scheduled by #{username} for #{post.scheduled_at}")
        {:reply, {:ok, post_id}, %{state | counter: state.counter + 1}}
    end
  end

  @impl true
  def handle_call({:list, username}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    posts = :dets.foldl(fn
      {_id, %{username: ^username_lower} = post}, acc -> [post | acc]
      _, acc -> acc
    end, [], @table)

    sorted = Enum.sort_by(posts, & &1.scheduled_at)
    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:get, post_id}, _from, state) do
    case :dets.lookup(@table, post_id) do
      [{^post_id, post}] -> {:reply, {:ok, post}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:cancel, username, post_id}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table, post_id) do
      [{^post_id, %{username: ^username_lower, status: :pending} = post}] ->
        updated = %{post | status: :cancelled, updated_at: DateTime.utc_now() |> DateTime.to_iso8601()}
        :dets.insert(@table, {post_id, updated})
        Logger.info("[ScheduledPosts] Post ##{post_id} cancelled")
        {:reply, :ok, state}

      [{^post_id, %{username: ^username_lower, status: status}}] ->
        {:reply, {:error, {:invalid_status, status}}, state}

      [{^post_id, _}] ->
        {:reply, {:error, :unauthorized}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update, username, post_id, updates}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table, post_id) do
      [{^post_id, %{username: ^username_lower, status: :pending} = post}] ->
        updated = post
          |> maybe_update_field(:title, updates)
          |> maybe_update_field(:body, updates)
          |> maybe_update_field(:tags, updates)
          |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

        :dets.insert(@table, {post_id, updated})
        {:reply, {:ok, updated}, state}

      [{^post_id, %{status: status}}] ->
        {:reply, {:error, {:invalid_status, status}}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:reschedule, username, post_id, new_scheduled_at}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    cond do
      not valid_schedule_time?(new_scheduled_at) ->
        {:reply, {:error, :invalid_schedule_time}, state}

      true ->
        case :dets.lookup(@table, post_id) do
          [{^post_id, %{username: ^username_lower, status: :pending} = post}] ->
            updated = %{post |
              scheduled_at: format_datetime(new_scheduled_at),
              updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }

            :dets.insert(@table, {post_id, updated})
            Logger.info("[ScheduledPosts] Post ##{post_id} rescheduled to #{updated.scheduled_at}")
            {:reply, {:ok, updated}, state}

          [{^post_id, %{status: status}}] ->
            {:reply, {:error, {:invalid_status, status}}, state}

          [] ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = :dets.foldl(fn {_id, post}, acc ->
      acc
      |> Map.update(:total, 1, & &1 + 1)
      |> Map.update(post.status, 1, & &1 + 1)
    end, %{total: 0, pending: 0, published: 0, cancelled: 0, failed: 0}, @table)

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:check_scheduled, state) do
    publish_due_posts()
    schedule_check()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # Private functions

  defp get_counter do
    case :dets.foldl(fn {id, _}, max -> max(id, max) end, 0, @table) do
      0 -> 1
      n -> n + 1
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_scheduled, @check_interval_ms)
  end

  defp valid_schedule_time?(scheduled_at) do
    now = DateTime.utc_now()
    min_time = DateTime.add(now, @min_schedule_ahead_minutes * 60, :second)

    case scheduled_at do
      %DateTime{} = dt ->
        DateTime.compare(dt, min_time) in [:gt, :eq]

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _} -> DateTime.compare(dt, min_time) in [:gt, :eq]
          _ -> false
        end

      _ ->
        false
    end
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(str) when is_binary(str), do: str

  defp user_count(username_lower) do
    :dets.foldl(fn
      {_id, %{username: ^username_lower, status: :pending}}, acc -> acc + 1
      _, acc -> acc
    end, 0, @table)
  end

  defp maybe_update_field(post, field, updates) do
    case Keyword.get(updates, field) do
      nil -> post
      value -> Map.put(post, field, value)
    end
  end

  defp publish_due_posts do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    due_posts = :dets.foldl(fn
      {id, %{status: :pending, scheduled_at: scheduled_at} = post}, acc
          when scheduled_at <= now ->
        [{id, post} | acc]
      _, acc ->
        acc
    end, [], @table)

    Enum.each(due_posts, fn {id, post} ->
      publish_post(id, post)
    end)
  end

  defp publish_post(id, post) do
    # Try to publish to UserPhlog
    result = case Code.ensure_loaded(PureGopherAi.UserPhlog) do
      {:module, _} ->
        # Create the post directly (bypassing auth since it's scheduled)
        PureGopherAi.UserPhlog.create_post_internal(
          post.username,
          post.title,
          post.body,
          tags: post.tags
        )
      _ ->
        {:error, :module_not_loaded}
    end

    case result do
      {:ok, _post_id} ->
        updated = %{post |
          status: :published,
          published_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
        :dets.insert(@table, {id, updated})
        Logger.info("[ScheduledPosts] Published post ##{id} for #{post.username}")

      {:error, reason} ->
        updated = %{post |
          status: :failed,
          error: inspect(reason),
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
        :dets.insert(@table, {id, updated})
        Logger.error("[ScheduledPosts] Failed to publish post ##{id}: #{inspect(reason)}")
    end
  end
end
