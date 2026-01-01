defmodule PureGopherAi.Notifications do
  @moduledoc """
  User notification system.

  Tracks notifications for users about:
  - New messages
  - Replies to their posts/comments
  - Mentions
  - System announcements
  - Phlog comments
  """

  use GenServer
  require Logger

  @table :notifications
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_notifications_per_user 100
  @notification_ttl_days 30
  @cleanup_interval_ms 24 * 60 * 60 * 1000  # Daily

  # Notification types
  @types [:message, :reply, :mention, :comment, :system, :announcement]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a notification for a user.
  """
  def notify(username, type, title, content, opts \\ [])
      when type in @types do
    GenServer.cast(__MODULE__, {:notify, username, type, title, content, opts})
  end

  @doc """
  Convenience function to notify about a new message.
  """
  def new_message(to_username, from_username, subject) do
    notify(to_username, :message, "New message from #{from_username}", subject,
      link: "/mail/inbox",
      from: from_username
    )
  end

  @doc """
  Convenience function to notify about a reply to a post.
  """
  def new_reply(to_username, from_username, post_title, post_path) do
    notify(to_username, :reply, "#{from_username} replied to your post", post_title,
      link: post_path,
      from: from_username
    )
  end

  @doc """
  Convenience function to notify about a mention.
  """
  def mentioned(to_username, from_username, context, context_link) do
    notify(to_username, :mention, "#{from_username} mentioned you", context,
      link: context_link,
      from: from_username
    )
  end

  @doc """
  Convenience function to notify about a phlog comment.
  """
  def new_comment(to_username, from_username, post_title, post_path) do
    notify(to_username, :comment, "New comment on #{post_title}", "From #{from_username}",
      link: post_path,
      from: from_username
    )
  end

  @doc """
  Convenience function for system notifications.
  """
  def system_notification(username, title, content, opts \\ []) do
    notify(username, :system, title, content, opts)
  end

  @doc """
  Sends an announcement to all users (or a subset).
  """
  def announce(title, content, opts \\ []) do
    GenServer.cast(__MODULE__, {:announce, title, content, opts})
  end

  @doc """
  Gets notifications for a user.
  Requires passphrase authentication (via caller).
  """
  def get_notifications(username, opts \\ []) do
    GenServer.call(__MODULE__, {:get, username, opts})
  end

  @doc """
  Gets unread notification count for a user.
  """
  def unread_count(username) do
    GenServer.call(__MODULE__, {:unread_count, username})
  end

  @doc """
  Marks a notification as read.
  """
  def mark_read(username, notification_id) do
    GenServer.call(__MODULE__, {:mark_read, username, notification_id})
  end

  @doc """
  Marks all notifications as read for a user.
  """
  def mark_all_read(username) do
    GenServer.call(__MODULE__, {:mark_all_read, username})
  end

  @doc """
  Deletes a notification.
  """
  def delete(username, notification_id) do
    GenServer.call(__MODULE__, {:delete, username, notification_id})
  end

  @doc """
  Clears all notifications for a user.
  """
  def clear_all(username) do
    GenServer.call(__MODULE__, {:clear_all, username})
  end

  @doc """
  Gets notification statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "notifications.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: dets_file, type: :set)

    schedule_cleanup()

    Logger.info("[Notifications] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:notify, username, type, title, content, opts}, state) do
    username_lower = String.downcase(String.trim(username))
    notification_id = generate_id()

    notification = %{
      id: notification_id,
      type: type,
      title: title,
      content: content,
      link: Keyword.get(opts, :link),
      from: Keyword.get(opts, :from),
      read: false,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Get existing notifications
    notifications = get_user_notifications(username_lower)

    # Add new notification, trim to max
    updated = [notification | notifications]
      |> Enum.take(@max_notifications_per_user)

    :dets.insert(@table, {username_lower, updated})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:announce, title, content, opts}, state) do
    # Get list of all users with profiles
    users = case Code.ensure_loaded(PureGopherAi.UserProfiles) do
      {:module, _} ->
        case PureGopherAi.UserProfiles.list() do
          {:ok, profiles, _count} ->
            Enum.map(profiles, & &1.username_lower)
          _ ->
            []
        end
      _ ->
        []
    end

    # Send to each user
    Enum.each(users, fn username ->
      notify(username, :announcement, title, content, opts)
    end)

    Logger.info("[Notifications] Announcement sent to #{length(users)} users: #{title}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:get, username, opts}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    unread_only = Keyword.get(opts, :unread_only, false)

    notifications = get_user_notifications(username_lower)
      |> maybe_filter_unread(unread_only)
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:reply, {:ok, notifications}, state}
  end

  @impl true
  def handle_call({:unread_count, username}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    count = get_user_notifications(username_lower)
      |> Enum.count(fn n -> not n.read end)

    {:reply, count, state}
  end

  @impl true
  def handle_call({:mark_read, username, notification_id}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    notifications = get_user_notifications(username_lower)
    updated = Enum.map(notifications, fn n ->
      if n.id == notification_id, do: %{n | read: true}, else: n
    end)

    :dets.insert(@table, {username_lower, updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:mark_all_read, username}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    notifications = get_user_notifications(username_lower)
    updated = Enum.map(notifications, &%{&1 | read: true})

    :dets.insert(@table, {username_lower, updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, username, notification_id}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    notifications = get_user_notifications(username_lower)
    updated = Enum.reject(notifications, &(&1.id == notification_id))

    :dets.insert(@table, {username_lower, updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear_all, username}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    :dets.delete(@table, username_lower)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = :dets.foldl(fn {_username, notifications}, acc ->
      unread = Enum.count(notifications, &(not &1.read))

      acc
      |> Map.update(:total_users, 1, & &1 + 1)
      |> Map.update(:total_notifications, length(notifications), & &1 + length(notifications))
      |> Map.update(:total_unread, unread, & &1 + unread)
    end, %{total_users: 0, total_notifications: 0, total_unread: 0}, @table)

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp get_user_notifications(username_lower) do
    case :dets.lookup(@table, username_lower) do
      [{^username_lower, notifications}] -> notifications
      [] -> []
    end
  end

  defp maybe_filter_unread(notifications, true) do
    Enum.filter(notifications, &(not &1.read))
  end
  defp maybe_filter_unread(notifications, _), do: notifications

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    cutoff = DateTime.utc_now()
      |> DateTime.add(-@notification_ttl_days * 24 * 60 * 60, :second)
      |> DateTime.to_iso8601()

    :dets.foldl(fn {username, notifications}, _acc ->
      filtered = Enum.reject(notifications, fn n ->
        n.created_at < cutoff
      end)

      if length(filtered) != length(notifications) do
        :dets.insert(@table, {username, filtered})
      end
    end, nil, @table)

    :dets.sync(@table)
  end
end
