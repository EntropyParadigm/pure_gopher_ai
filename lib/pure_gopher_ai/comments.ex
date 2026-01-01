defmodule PureGopherAi.Comments do
  @moduledoc """
  Threaded comments system for phlog posts and other content.

  Features:
  - Add comments on content
  - Reply to comments (threaded)
  - Edit/delete own comments
  - Content moderation
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserProfiles
  alias PureGopherAi.ContentModerator
  alias PureGopherAi.Notifications
  alias PureGopherAi.InputSanitizer

  @table_name :comments
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_comment_length 2000
  @max_comments_per_item 500
  @max_depth 5

  # Content types that can have comments
  @content_types [:phlog, :bulletin, :document]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a comment to content.
  parent_id is nil for top-level comments, or the ID of the comment being replied to.
  """
  def add_comment(username, passphrase, content_type, content_id, body, parent_id \\ nil) do
    GenServer.call(__MODULE__, {:add, username, passphrase, content_type, content_id, body, parent_id}, 30_000)
  end

  @doc """
  Edits a comment. Only the author can edit.
  """
  def edit_comment(username, passphrase, comment_id, body) do
    GenServer.call(__MODULE__, {:edit, username, passphrase, comment_id, body}, 30_000)
  end

  @doc """
  Deletes a comment. Only the author can delete.
  """
  def delete_comment(username, passphrase, comment_id) do
    GenServer.call(__MODULE__, {:delete, username, passphrase, comment_id})
  end

  @doc """
  Gets all comments for content item, organized as a tree.
  """
  def get_comments(content_type, content_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get, content_type, content_id, opts})
  end

  @doc """
  Gets a single comment by ID.
  """
  def get_comment(comment_id) do
    GenServer.call(__MODULE__, {:get_one, comment_id})
  end

  @doc """
  Gets comment count for content.
  """
  def count(content_type, content_id) do
    GenServer.call(__MODULE__, {:count, content_type, content_id})
  end

  @doc """
  Gets recent comments across all content.
  """
  def recent(opts \\ []) do
    GenServer.call(__MODULE__, {:recent, opts})
  end

  @doc """
  Gets comments by a specific user.
  """
  def user_comments(username, opts \\ []) do
    GenServer.call(__MODULE__, {:user_comments, username, opts})
  end

  @doc """
  Returns valid content types.
  """
  def content_types, do: @content_types

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "comments.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    Logger.info("[Comments] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add, username, passphrase, content_type, content_id, body, parent_id}, _from, state) do
    cond do
      content_type not in @content_types ->
        {:reply, {:error, :invalid_content_type}, state}

      String.length(String.trim(body)) == 0 ->
        {:reply, {:error, :empty_comment}, state}

      String.length(body) > @max_comment_length ->
        {:reply, {:error, :comment_too_long}, state}

      true ->
        case UserProfiles.authenticate(username, passphrase) do
          {:ok, _profile} ->
            username_lower = String.downcase(String.trim(username))

            # Check comment limit
            current_count = count_comments(content_type, content_id)
            if current_count >= @max_comments_per_item do
              {:reply, {:error, :comment_limit_reached}, state}
            else
              # Check parent exists and get depth
              {parent_valid, depth} = validate_parent(parent_id)

              cond do
                parent_id != nil and not parent_valid ->
                  {:reply, {:error, :parent_not_found}, state}

                depth >= @max_depth ->
                  {:reply, {:error, :max_depth_reached}, state}

                true ->
                  # Sanitize content
                  clean_body = InputSanitizer.sanitize(body, allow_newlines: true)

                  # Content moderation
                  case ContentModerator.moderate(clean_body, :comment) do
                    {:ok, :approved} ->
                      comment_id = generate_id()
                      now = DateTime.utc_now() |> DateTime.to_iso8601()

                      comment = %{
                        id: comment_id,
                        content_type: content_type,
                        content_id: content_id,
                        parent_id: parent_id,
                        depth: depth,
                        author: username,
                        author_lower: username_lower,
                        body: clean_body,
                        created_at: now,
                        updated_at: now,
                        deleted: false
                      }

                      :dets.insert(@table_name, {comment_id, comment})
                      :dets.sync(@table_name)

                      # Notify if replying to someone
                      if parent_id do
                        notify_reply(parent_id, username, clean_body)
                      end

                      Logger.info("[Comments] Comment added by #{username} on #{content_type}/#{content_id}")
                      {:reply, {:ok, comment}, state}

                    {:error, :blocked, reason} ->
                      {:reply, {:error, :content_blocked, reason}, state}
                  end
              end
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:edit, username, passphrase, comment_id, body}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))

        case :dets.lookup(@table_name, comment_id) do
          [{^comment_id, comment}] ->
            cond do
              comment.author_lower != username_lower ->
                {:reply, {:error, :not_author}, state}

              comment.deleted ->
                {:reply, {:error, :comment_deleted}, state}

              String.length(body) > @max_comment_length ->
                {:reply, {:error, :comment_too_long}, state}

              true ->
                clean_body = InputSanitizer.sanitize(body, allow_newlines: true)

                case ContentModerator.moderate(clean_body, :comment) do
                  {:ok, :approved} ->
                    updated = %{comment |
                      body: clean_body,
                      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
                    }

                    :dets.insert(@table_name, {comment_id, updated})
                    :dets.sync(@table_name)

                    {:reply, {:ok, updated}, state}

                  {:error, :blocked, reason} ->
                    {:reply, {:error, :content_blocked, reason}, state}
                end
            end

          [] ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete, username, passphrase, comment_id}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))

        case :dets.lookup(@table_name, comment_id) do
          [{^comment_id, comment}] ->
            if comment.author_lower != username_lower do
              {:reply, {:error, :not_author}, state}
            else
              # Soft delete - preserve thread structure
              updated = %{comment |
                body: "[deleted]",
                deleted: true,
                updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }

              :dets.insert(@table_name, {comment_id, updated})
              :dets.sync(@table_name)

              {:reply, :ok, state}
            end

          [] ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get, content_type, content_id, opts}, _from, state) do
    flat = Keyword.get(opts, :flat, false)

    # Get all comments for this content
    comments = :dets.foldl(fn {_id, comment}, acc ->
      if comment.content_type == content_type and comment.content_id == content_id do
        [sanitize_comment(comment) | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.sort_by(& &1.created_at)

    result = if flat do
      comments
    else
      build_tree(comments)
    end

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:get_one, comment_id}, _from, state) do
    case :dets.lookup(@table_name, comment_id) do
      [{^comment_id, comment}] ->
        {:reply, {:ok, sanitize_comment(comment)}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:count, content_type, content_id}, _from, state) do
    count = count_comments(content_type, content_id)
    {:reply, count, state}
  end

  @impl true
  def handle_call({:recent, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    content_type = Keyword.get(opts, :type)

    comments = :dets.foldl(fn {_id, comment}, acc ->
      type_match = is_nil(content_type) or comment.content_type == content_type

      if type_match and not comment.deleted do
        [sanitize_comment(comment) | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.sort_by(& &1.created_at, :desc)
    |> Enum.take(limit)

    {:reply, {:ok, comments}, state}
  end

  @impl true
  def handle_call({:user_comments, username, opts}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    limit = Keyword.get(opts, :limit, 50)

    comments = :dets.foldl(fn {_id, comment}, acc ->
      if comment.author_lower == username_lower and not comment.deleted do
        [sanitize_comment(comment) | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.sort_by(& &1.created_at, :desc)
    |> Enum.take(limit)

    {:reply, {:ok, comments}, state}
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

  defp count_comments(content_type, content_id) do
    :dets.foldl(fn {_id, comment}, acc ->
      if comment.content_type == content_type and comment.content_id == content_id do
        acc + 1
      else
        acc
      end
    end, 0, @table_name)
  end

  defp validate_parent(nil), do: {true, 0}
  defp validate_parent(parent_id) do
    case :dets.lookup(@table_name, parent_id) do
      [{^parent_id, parent}] -> {true, parent.depth + 1}
      [] -> {false, 0}
    end
  end

  defp notify_reply(parent_id, replier, body) do
    case :dets.lookup(@table_name, parent_id) do
      [{^parent_id, parent}] ->
        if parent.author_lower != String.downcase(replier) do
          Notifications.create(
            parent.author_lower,
            :reply,
            "Reply to your comment",
            "#{replier}: #{String.slice(body, 0, 100)}",
            %{comment_id: parent_id, replier: replier}
          )
        end

      [] ->
        :ok
    end
  end

  defp sanitize_comment(comment) do
    Map.take(comment, [:id, :content_type, :content_id, :parent_id, :depth,
                        :author, :body, :created_at, :updated_at, :deleted])
  end

  defp build_tree(comments) do
    # Group by parent_id
    by_parent = Enum.group_by(comments, & &1.parent_id)

    # Build tree starting from root comments (parent_id: nil)
    root_comments = Map.get(by_parent, nil, [])
    Enum.map(root_comments, &add_children(&1, by_parent))
  end

  defp add_children(comment, by_parent) do
    children = Map.get(by_parent, comment.id, [])
    children_with_nested = Enum.map(children, &add_children(&1, by_parent))
    Map.put(comment, :replies, children_with_nested)
  end
end
