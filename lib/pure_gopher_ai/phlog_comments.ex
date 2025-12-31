defmodule PureGopherAi.PhlogComments do
  @moduledoc """
  Comment system for phlog entries.

  Features:
  - Add comments to any phlog entry
  - Rate limiting per IP
  - Author name and message
  - Admin moderation
  - Comments stored by phlog path
  """

  use GenServer
  require Logger

  @table_name :phlog_comments
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @cooldown_ms 60_000  # 1 minute between comments per IP
  @max_name_length 50
  @max_message_length 1000
  @max_comments_per_entry 100

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a comment to a phlog entry.

  The entry_path should be the phlog path (e.g., "2025/01/01-hello")
  """
  def add_comment(entry_path, author, message, ip) do
    GenServer.call(__MODULE__, {:add_comment, entry_path, author, message, ip})
  end

  @doc """
  Gets all comments for a phlog entry.
  """
  def get_comments(entry_path, opts \\ []) do
    GenServer.call(__MODULE__, {:get_comments, entry_path, opts})
  end

  @doc """
  Counts comments for a phlog entry.
  """
  def count_comments(entry_path) do
    GenServer.call(__MODULE__, {:count_comments, entry_path})
  end

  @doc """
  Deletes a specific comment (admin only).
  """
  def delete_comment(comment_id) do
    GenServer.call(__MODULE__, {:delete_comment, comment_id})
  end

  @doc """
  Deletes all comments for a phlog entry (admin only).
  """
  def delete_all_comments(entry_path) do
    GenServer.call(__MODULE__, {:delete_all_comments, entry_path})
  end

  @doc """
  Gets recent comments across all entries.
  """
  def recent_comments(limit \\ 20) do
    GenServer.call(__MODULE__, {:recent_comments, limit})
  end

  @doc """
  Gets comment statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "phlog_comments.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Track cooldowns in ETS
    :ets.new(:phlog_comment_cooldowns, [:named_table, :public, :set])

    Logger.info("[PhlogComments] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_comment, entry_path, author, message, ip}, _from, state) do
    ip_hash = hash_ip(ip)
    now = System.system_time(:millisecond)

    cond do
      # Rate limit check
      check_cooldown(ip_hash, now) == :rate_limited ->
        {:reply, {:error, :rate_limited}, state}

      # Validate author name
      String.trim(author) == "" ->
        {:reply, {:error, :empty_author}, state}

      String.length(author) > @max_name_length ->
        {:reply, {:error, :author_too_long}, state}

      # Validate message
      String.trim(message) == "" ->
        {:reply, {:error, :empty_message}, state}

      String.length(message) > @max_message_length ->
        {:reply, {:error, :message_too_long}, state}

      # Check max comments per entry
      count_comments_internal(entry_path) >= @max_comments_per_entry ->
        {:reply, {:error, :too_many_comments}, state}

      true ->
        comment_id = generate_id()
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        comment = %{
          id: comment_id,
          entry_path: entry_path,
          author: String.trim(author) |> sanitize_text(),
          message: String.trim(message) |> sanitize_text(),
          ip_hash: ip_hash,
          created_at: timestamp
        }

        :dets.insert(@table_name, {comment_id, comment})
        :dets.sync(@table_name)

        # Update cooldown
        :ets.insert(:phlog_comment_cooldowns, {ip_hash, now})

        Logger.info("[PhlogComments] Comment added to #{entry_path} by #{comment.author}")
        {:reply, {:ok, comment_id}, state}
    end
  end

  @impl true
  def handle_call({:get_comments, entry_path, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    order = Keyword.get(opts, :order, :desc)

    comments = :dets.foldl(fn {_id, comment}, acc ->
      if comment.entry_path == entry_path do
        [comment | acc]
      else
        acc
      end
    end, [], @table_name)

    sorted = case order do
      :asc -> Enum.sort_by(comments, & &1.created_at, :asc)
      :desc -> Enum.sort_by(comments, & &1.created_at, :desc)
    end

    {:reply, {:ok, Enum.take(sorted, limit)}, state}
  end

  @impl true
  def handle_call({:count_comments, entry_path}, _from, state) do
    count = count_comments_internal(entry_path)
    {:reply, count, state}
  end

  @impl true
  def handle_call({:delete_comment, comment_id}, _from, state) do
    case :dets.lookup(@table_name, comment_id) do
      [{^comment_id, _}] ->
        :dets.delete(@table_name, comment_id)
        :dets.sync(@table_name)
        Logger.info("[PhlogComments] Deleted comment #{comment_id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_all_comments, entry_path}, _from, state) do
    deleted = :dets.foldl(fn {id, comment}, count ->
      if comment.entry_path == entry_path do
        :dets.delete(@table_name, id)
        count + 1
      else
        count
      end
    end, 0, @table_name)

    if deleted > 0, do: :dets.sync(@table_name)
    Logger.info("[PhlogComments] Deleted #{deleted} comments for #{entry_path}")
    {:reply, {:ok, deleted}, state}
  end

  @impl true
  def handle_call({:recent_comments, limit}, _from, state) do
    comments = :dets.foldl(fn {_id, comment}, acc ->
      [comment | acc]
    end, [], @table_name)

    recent = comments
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, recent}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {total, entries_with_comments} =
      :dets.foldl(fn {_id, comment}, {t, entries} ->
        {t + 1, MapSet.put(entries, comment.entry_path)}
      end, {0, MapSet.new()}, @table_name)

    {:reply, %{
      total_comments: total,
      entries_with_comments: MapSet.size(entries_with_comments)
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

  defp hash_ip(ip) when is_tuple(ip) do
    ip_str = case ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
    end
    :crypto.hash(:sha256, ip_str) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp hash_ip(_), do: "unknown"

  defp check_cooldown(ip_hash, now) do
    case :ets.lookup(:phlog_comment_cooldowns, ip_hash) do
      [{^ip_hash, last_comment}] when now - last_comment < @cooldown_ms ->
        :rate_limited
      _ ->
        :ok
    end
  end

  defp count_comments_internal(entry_path) do
    :dets.foldl(fn {_id, comment}, count ->
      if comment.entry_path == entry_path, do: count + 1, else: count
    end, 0, @table_name)
  end

  defp sanitize_text(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")  # Strip HTML tags
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")  # Strip control chars
    |> String.trim()
  end
end
