defmodule PureGopherAi.UserExport do
  @moduledoc """
  User data export functionality.

  Allows users to export all their data in a portable format:
  - Profile information
  - Phlog posts
  - Messages (inbox and sent)
  - Bookmarks
  - Guestbook entries
  - Poll votes
  - Notifications
  """

  require Logger

  alias PureGopherAi.UserProfiles
  alias PureGopherAi.UserPhlog
  alias PureGopherAi.Mailbox
  alias PureGopherAi.Bookmarks
  alias PureGopherAi.Notifications

  @doc """
  Exports all user data. Requires authentication.
  Returns {:ok, export_data} or {:error, reason}.
  """
  def export(username, passphrase) do
    # Authenticate first
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, profile} ->
        export_data = %{
          exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          username: username,
          profile: export_profile(profile),
          phlog_posts: export_phlog(username),
          messages: export_messages(username, passphrase),
          bookmarks: export_bookmarks(username, passphrase),
          notifications: export_notifications(username),
          metadata: %{
            format_version: "1.0",
            server: "PureGopherAI",
            export_type: "full"
          }
        }

        {:ok, export_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exports user data as a text file suitable for Gopher viewing.
  """
  def export_text(username, passphrase) do
    case export(username, passphrase) do
      {:ok, data} ->
        text = format_as_text(data)
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exports user data as JSON.
  """
  def export_json(username, passphrase) do
    case export(username, passphrase) do
      {:ok, data} ->
        {:ok, Jason.encode!(data, pretty: true)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private export functions

  defp export_profile(profile) do
    profile
    |> Map.take([:username, :bio, :links, :interests, :created_at, :updated_at])
  end

  defp export_phlog(username) do
    case UserPhlog.list_posts(username, limit: 1000) do
      {:ok, posts} ->
        Enum.map(posts, fn post ->
          Map.take(post, [:id, :title, :body, :created_at, :updated_at, :views])
        end)
      _ ->
        []
    end
  end

  defp export_messages(username, passphrase) do
    inbox = case Mailbox.get_inbox(username, passphrase, limit: 500) do
      {:ok, messages} -> messages
      _ -> []
    end

    sent = case Mailbox.get_sent(username, passphrase, limit: 500) do
      {:ok, messages} -> messages
      _ -> []
    end

    %{
      inbox: Enum.map(inbox, &sanitize_message/1),
      sent: Enum.map(sent, &sanitize_message/1)
    }
  end

  defp sanitize_message(msg) do
    Map.take(msg, [:id, :from, :to, :subject, :body, :read, :created_at])
  end

  defp export_bookmarks(username, passphrase) do
    case Bookmarks.list(username, passphrase) do
      {:ok, bookmarks} ->
        Enum.map(bookmarks, fn b ->
          Map.take(b, [:id, :title, :url, :folder, :notes, :created_at])
        end)
      _ ->
        []
    end
  end

  defp export_notifications(username) do
    case Notifications.get_notifications(username, limit: 100) do
      {:ok, notifications} ->
        Enum.map(notifications, fn n ->
          Map.take(n, [:id, :type, :title, :content, :read, :created_at])
        end)
      _ ->
        []
    end
  end

  # Text formatting

  defp format_as_text(data) do
    """
    ================================================================================
                              USER DATA EXPORT
    ================================================================================

    Exported: #{data.exported_at}
    Username: #{data.username}

    ================================================================================
                                  PROFILE
    ================================================================================

    #{format_profile(data.profile)}

    ================================================================================
                               PHLOG POSTS (#{length(data.phlog_posts)})
    ================================================================================

    #{format_posts(data.phlog_posts)}

    ================================================================================
                          MESSAGES - INBOX (#{length(data.messages.inbox)})
    ================================================================================

    #{format_messages(data.messages.inbox)}

    ================================================================================
                           MESSAGES - SENT (#{length(data.messages.sent)})
    ================================================================================

    #{format_messages(data.messages.sent)}

    ================================================================================
                              BOOKMARKS (#{length(data.bookmarks)})
    ================================================================================

    #{format_bookmarks(data.bookmarks)}

    ================================================================================
                            NOTIFICATIONS (#{length(data.notifications)})
    ================================================================================

    #{format_notifications(data.notifications)}

    ================================================================================
                                END OF EXPORT
    ================================================================================
    """
  end

  defp format_profile(profile) do
    bio = Map.get(profile, :bio, "(none)")
    interests = case Map.get(profile, :interests, []) do
      [] -> "(none)"
      list -> Enum.join(list, ", ")
    end
    links = case Map.get(profile, :links, []) do
      [] -> "(none)"
      list ->
        Enum.map(list, fn {title, url} -> "  - #{title}: #{url}" end)
        |> Enum.join("\n")
    end

    """
    Bio: #{bio}
    Interests: #{interests}
    Links:
    #{links}
    Created: #{Map.get(profile, :created_at, "unknown")}
    """
  end

  defp format_posts([]), do: "(no posts)"
  defp format_posts(posts) do
    posts
    |> Enum.map(fn post ->
      """
      --- #{post.title} ---
      ID: #{post.id}
      Created: #{post.created_at}
      Views: #{post.views}

      #{post.body}

      """
    end)
    |> Enum.join("\n")
  end

  defp format_messages([]), do: "(no messages)"
  defp format_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      read_status = if msg.read, do: "[READ]", else: "[UNREAD]"
      """
      #{read_status} From: #{msg.from} | To: #{msg.to}
      Subject: #{msg.subject}
      Date: #{msg.created_at}

      #{msg.body}

      ---
      """
    end)
    |> Enum.join("\n")
  end

  defp format_bookmarks([]), do: "(no bookmarks)"
  defp format_bookmarks(bookmarks) do
    bookmarks
    |> Enum.map(fn b ->
      folder = Map.get(b, :folder, "")
      folder_str = if folder != "", do: "[#{folder}] ", else: ""
      notes = Map.get(b, :notes, "")
      notes_str = if notes != "", do: " - #{notes}", else: ""
      "#{folder_str}#{b.title}: #{b.url}#{notes_str}"
    end)
    |> Enum.join("\n")
  end

  defp format_notifications([]), do: "(no notifications)"
  defp format_notifications(notifications) do
    notifications
    |> Enum.map(fn n ->
      read_status = if n.read, do: "[READ]", else: "[NEW]"
      "[#{n.type}] #{read_status} #{n.title}: #{n.content}"
    end)
    |> Enum.join("\n")
  end
end
