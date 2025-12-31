defmodule PureGopherAi.BulletinBoard do
  @moduledoc """
  Simple bulletin board / message board for community discussions.

  Features:
  - Multiple boards/topics
  - Threaded discussions
  - Persistent storage via DETS
  - Rate limiting per IP
  - Basic moderation (admin delete)
  """

  use GenServer
  require Logger

  @table_name :bulletin_board
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_posts_per_board 500
  @max_title_length 100
  @max_body_length 4000

  @default_boards %{
    "general" => %{
      name: "General Discussion",
      description: "Off-topic chat and community discussions"
    },
    "tech" => %{
      name: "Tech Talk",
      description: "Technology, programming, and computing"
    },
    "gopher" => %{
      name: "Gopher Protocol",
      description: "Gopher servers, clients, and development"
    },
    "gemini" => %{
      name: "Gemini Protocol",
      description: "Gemini capsules, clients, and the small web"
    },
    "retro" => %{
      name: "Retro Computing",
      description: "Vintage computers, retrocomputing, and nostalgia"
    },
    "creative" => %{
      name: "Creative Corner",
      description: "ASCII art, writing, music, and creative projects"
    },
    "help" => %{
      name: "Help & Support",
      description: "Questions, troubleshooting, and assistance"
    }
  }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all boards with post counts.
  """
  def list_boards do
    GenServer.call(__MODULE__, :list_boards)
  end

  @doc """
  Get board info and threads.
  """
  def get_board(board_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_board, board_id, opts})
  end

  @doc """
  Get a specific thread with all replies.
  """
  def get_thread(board_id, thread_id) do
    GenServer.call(__MODULE__, {:get_thread, board_id, thread_id})
  end

  @doc """
  Create a new thread.
  """
  def create_thread(board_id, title, body, author \\ "Anonymous", ip \\ nil) do
    GenServer.call(__MODULE__, {:create_thread, board_id, title, body, author, ip})
  end

  @doc """
  Reply to a thread.
  """
  def reply(board_id, thread_id, body, author \\ "Anonymous", ip \\ nil) do
    GenServer.call(__MODULE__, {:reply, board_id, thread_id, body, author, ip})
  end

  @doc """
  Delete a post (admin).
  """
  def delete_post(board_id, post_id) do
    GenServer.call(__MODULE__, {:delete_post, board_id, post_id})
  end

  @doc """
  Get statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Get recent posts across all boards.
  """
  def recent(limit \\ 10) do
    GenServer.call(__MODULE__, {:recent, limit})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "bulletin_board.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    {:ok, %{boards: @default_boards}}
  end

  @impl true
  def handle_call(:list_boards, _from, state) do
    boards = state.boards
      |> Enum.map(fn {id, info} ->
        posts = get_board_posts(id)
        threads = Enum.filter(posts, fn p -> p.type == :thread end)
        last_activity = posts |> Enum.map(& &1.created_at) |> Enum.max(fn -> nil end)

        %{
          id: id,
          name: info.name,
          description: info.description,
          thread_count: length(threads),
          post_count: length(posts),
          last_activity: last_activity
        }
      end)
      |> Enum.sort_by(fn b -> b.last_activity || "" end, :desc)

    {:reply, {:ok, boards}, state}
  end

  @impl true
  def handle_call({:get_board, board_id, opts}, _from, state) do
    case Map.get(state.boards, board_id) do
      nil ->
        {:reply, {:error, :board_not_found}, state}

      info ->
        page = Keyword.get(opts, :page, 1)
        per_page = Keyword.get(opts, :per_page, 20)

        posts = get_board_posts(board_id)
        threads = posts
          |> Enum.filter(fn p -> p.type == :thread end)
          |> Enum.map(fn thread ->
            replies = Enum.filter(posts, fn p ->
              p.type == :reply and p.thread_id == thread.id
            end)
            last_reply = replies |> Enum.map(& &1.created_at) |> Enum.max(fn -> thread.created_at end)
            Map.merge(thread, %{reply_count: length(replies), last_activity: last_reply})
          end)
          |> Enum.sort_by(fn t -> t.last_activity end, :desc)

        total = length(threads)
        offset = (page - 1) * per_page
        page_threads = Enum.slice(threads, offset, per_page)

        {:reply, {:ok, %{
          info: info,
          threads: page_threads,
          total: total,
          page: page,
          total_pages: ceil(total / per_page)
        }}, state}
    end
  end

  @impl true
  def handle_call({:get_thread, board_id, thread_id}, _from, state) do
    case Map.get(state.boards, board_id) do
      nil ->
        {:reply, {:error, :board_not_found}, state}

      _info ->
        posts = get_board_posts(board_id)

        case Enum.find(posts, fn p -> p.id == thread_id and p.type == :thread end) do
          nil ->
            {:reply, {:error, :thread_not_found}, state}

          thread ->
            replies = posts
              |> Enum.filter(fn p -> p.type == :reply and p.thread_id == thread_id end)
              |> Enum.sort_by(& &1.created_at)

            {:reply, {:ok, %{thread: thread, replies: replies}}, state}
        end
    end
  end

  @impl true
  def handle_call({:create_thread, board_id, title, body, author, ip}, _from, state) do
    cond do
      not Map.has_key?(state.boards, board_id) ->
        {:reply, {:error, :board_not_found}, state}

      String.length(title) > @max_title_length ->
        {:reply, {:error, :title_too_long}, state}

      String.length(body) > @max_body_length ->
        {:reply, {:error, :body_too_long}, state}

      String.trim(title) == "" or String.trim(body) == "" ->
        {:reply, {:error, :empty_content}, state}

      true ->
        thread_id = generate_id()
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        thread = %{
          id: thread_id,
          board_id: board_id,
          type: :thread,
          title: sanitize(title),
          body: sanitize(body),
          author: sanitize(author || "Anonymous"),
          ip: format_ip(ip),
          created_at: now,
          thread_id: nil
        }

        # Store in DETS
        key = {board_id, thread_id}
        :dets.insert(@table_name, {key, thread})
        :dets.sync(@table_name)

        # Prune old posts if needed
        prune_old_posts(board_id)

        {:reply, {:ok, thread_id}, state}
    end
  end

  @impl true
  def handle_call({:reply, board_id, thread_id, body, author, ip}, _from, state) do
    cond do
      not Map.has_key?(state.boards, board_id) ->
        {:reply, {:error, :board_not_found}, state}

      String.length(body) > @max_body_length ->
        {:reply, {:error, :body_too_long}, state}

      String.trim(body) == "" ->
        {:reply, {:error, :empty_content}, state}

      true ->
        # Verify thread exists
        posts = get_board_posts(board_id)
        thread = Enum.find(posts, fn p -> p.id == thread_id and p.type == :thread end)

        if thread do
          reply_id = generate_id()
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          reply = %{
            id: reply_id,
            board_id: board_id,
            type: :reply,
            title: nil,
            body: sanitize(body),
            author: sanitize(author || "Anonymous"),
            ip: format_ip(ip),
            created_at: now,
            thread_id: thread_id
          }

          key = {board_id, reply_id}
          :dets.insert(@table_name, {key, reply})
          :dets.sync(@table_name)

          {:reply, {:ok, reply_id}, state}
        else
          {:reply, {:error, :thread_not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:delete_post, board_id, post_id}, _from, state) do
    key = {board_id, post_id}

    case :dets.lookup(@table_name, key) do
      [{^key, post}] ->
        # If it's a thread, also delete replies
        if post.type == :thread do
          posts = get_board_posts(board_id)
          replies = Enum.filter(posts, fn p -> p.thread_id == post_id end)
          Enum.each(replies, fn r -> :dets.delete(@table_name, {board_id, r.id}) end)
        end

        :dets.delete(@table_name, key)
        :dets.sync(@table_name)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    all_posts = :dets.foldl(fn {_key, post}, acc -> [post | acc] end, [], @table_name)

    threads = Enum.filter(all_posts, fn p -> p.type == :thread end)
    replies = Enum.filter(all_posts, fn p -> p.type == :reply end)

    by_board = Enum.reduce(all_posts, %{}, fn post, acc ->
      Map.update(acc, post.board_id, 1, &(&1 + 1))
    end)

    {:reply, {:ok, %{
      total_threads: length(threads),
      total_replies: length(replies),
      total_posts: length(all_posts),
      by_board: by_board
    }}, state}
  end

  @impl true
  def handle_call({:recent, limit}, _from, state) do
    all_posts = :dets.foldl(fn {_key, post}, acc -> [post | acc] end, [], @table_name)

    recent = all_posts
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, recent}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp get_board_posts(board_id) do
    :dets.foldl(fn {{bid, _pid}, post}, acc ->
      if bid == board_id, do: [post | acc], else: acc
    end, [], @table_name)
  end

  defp prune_old_posts(board_id) do
    posts = get_board_posts(board_id)

    if length(posts) > @max_posts_per_board do
      # Keep newest posts, delete oldest
      to_delete = posts
        |> Enum.sort_by(& &1.created_at)
        |> Enum.take(length(posts) - @max_posts_per_board)

      Enum.each(to_delete, fn post ->
        :dets.delete(@table_name, {board_id, post.id})
      end)

      :dets.sync(@table_name)
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(nil), do: "unknown"
  defp format_ip(ip), do: inspect(ip)

  defp sanitize(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/<[^>]*>/, "")  # Remove HTML tags
    |> String.slice(0, @max_body_length)
  end

  defp sanitize(nil), do: ""
end
