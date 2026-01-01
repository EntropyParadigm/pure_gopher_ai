defmodule PureGopherAi.Bookmarks do
  @moduledoc """
  Bookmark / Favorites system for saving links to server content.

  Features:
  - User-based bookmark storage
  - Folder organization
  - Quick access to saved selectors
  - Import/export bookmarks
  """

  use GenServer
  require Logger

  @table_name :bookmarks
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_bookmarks_per_user 100
  @max_folders_per_user 10

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a bookmark for a user.
  """
  def add(username, selector, title, folder \\ "default") do
    GenServer.call(__MODULE__, {:add, username, selector, title, folder})
  end

  @doc """
  Removes a bookmark.
  """
  def remove(username, bookmark_id) do
    GenServer.call(__MODULE__, {:remove, username, bookmark_id})
  end

  @doc """
  Gets all bookmarks for a user.
  """
  def list(username, folder \\ nil) do
    GenServer.call(__MODULE__, {:list, username, folder})
  end

  @doc """
  Gets all folders for a user.
  """
  def folders(username) do
    GenServer.call(__MODULE__, {:folders, username})
  end

  @doc """
  Creates a new folder.
  """
  def create_folder(username, folder_name) do
    GenServer.call(__MODULE__, {:create_folder, username, folder_name})
  end

  @doc """
  Deletes a folder (and moves bookmarks to default).
  """
  def delete_folder(username, folder_name) do
    GenServer.call(__MODULE__, {:delete_folder, username, folder_name})
  end

  @doc """
  Moves a bookmark to a different folder.
  """
  def move(username, bookmark_id, new_folder) do
    GenServer.call(__MODULE__, {:move, username, bookmark_id, new_folder})
  end

  @doc """
  Gets a single bookmark by ID.
  """
  def get(username, bookmark_id) do
    GenServer.call(__MODULE__, {:get, username, bookmark_id})
  end

  @doc """
  Gets bookmark count for a user.
  """
  def count(username) do
    GenServer.call(__MODULE__, {:count, username})
  end

  @doc """
  Exports bookmarks as a simple text format.
  """
  def export(username) do
    GenServer.call(__MODULE__, {:export, username})
  end

  @doc """
  Gets stats.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "bookmarks.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    Logger.info("[Bookmarks] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add, username, selector, title, folder}, _from, state) do
    username = sanitize_username(username)
    folder = sanitize_folder(folder)
    title = sanitize_title(title)

    if username == "" do
      {:reply, {:error, :invalid_username}, state}
    else
      # Check bookmark limit
      current_count = get_bookmark_count(username)

      if current_count >= @max_bookmarks_per_user do
        {:reply, {:error, :limit_reached}, state}
      else
        # Check if already bookmarked
        existing = get_user_bookmarks(username)
        already_exists = Enum.any?(existing, fn b -> b.selector == selector end)

        if already_exists do
          {:reply, {:error, :already_exists}, state}
        else
          bookmark_id = generate_id()

          bookmark = %{
            id: bookmark_id,
            selector: selector,
            title: title,
            folder: folder,
            created_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }

          # Get or create user data
          user_data = get_user_data(username)
          updated_bookmarks = [bookmark | user_data.bookmarks]
          updated_folders = if folder in user_data.folders, do: user_data.folders, else: [folder | user_data.folders]

          updated_data = %{user_data |
            bookmarks: updated_bookmarks,
            folders: Enum.uniq(updated_folders)
          }

          :dets.insert(@table_name, {username, updated_data})
          :dets.sync(@table_name)

          Logger.info("[Bookmarks] #{username} added bookmark: #{selector}")
          {:reply, {:ok, bookmark}, state}
        end
      end
    end
  end

  @impl true
  def handle_call({:remove, username, bookmark_id}, _from, state) do
    username = sanitize_username(username)

    user_data = get_user_data(username)
    bookmark = Enum.find(user_data.bookmarks, &(&1.id == bookmark_id))

    if bookmark do
      updated_bookmarks = Enum.reject(user_data.bookmarks, &(&1.id == bookmark_id))
      updated_data = %{user_data | bookmarks: updated_bookmarks}

      :dets.insert(@table_name, {username, updated_data})
      :dets.sync(@table_name)

      Logger.info("[Bookmarks] #{username} removed bookmark: #{bookmark.selector}")
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list, username, folder}, _from, state) do
    username = sanitize_username(username)
    bookmarks = get_user_bookmarks(username)

    filtered = if folder do
      Enum.filter(bookmarks, &(&1.folder == folder))
    else
      bookmarks
    end

    sorted = Enum.sort_by(filtered, & &1.created_at, :desc)
    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:folders, username}, _from, state) do
    username = sanitize_username(username)
    user_data = get_user_data(username)

    # Ensure "default" is always first
    folders = user_data.folders
      |> Enum.reject(&(&1 == "default"))
      |> then(&(["default" | &1]))

    {:reply, {:ok, folders}, state}
  end

  @impl true
  def handle_call({:create_folder, username, folder_name}, _from, state) do
    username = sanitize_username(username)
    folder_name = sanitize_folder(folder_name)

    if folder_name == "" or folder_name == "default" do
      {:reply, {:error, :invalid_name}, state}
    else
      user_data = get_user_data(username)

      if length(user_data.folders) >= @max_folders_per_user do
        {:reply, {:error, :limit_reached}, state}
      else
        if folder_name in user_data.folders do
          {:reply, {:error, :already_exists}, state}
        else
          updated_data = %{user_data | folders: [folder_name | user_data.folders]}
          :dets.insert(@table_name, {username, updated_data})
          :dets.sync(@table_name)

          {:reply, :ok, state}
        end
      end
    end
  end

  @impl true
  def handle_call({:delete_folder, username, folder_name}, _from, state) do
    username = sanitize_username(username)

    if folder_name == "default" do
      {:reply, {:error, :cannot_delete_default}, state}
    else
      user_data = get_user_data(username)

      if folder_name not in user_data.folders do
        {:reply, {:error, :not_found}, state}
      else
        # Move bookmarks to default
        updated_bookmarks = Enum.map(user_data.bookmarks, fn b ->
          if b.folder == folder_name, do: %{b | folder: "default"}, else: b
        end)

        updated_folders = Enum.reject(user_data.folders, &(&1 == folder_name))

        updated_data = %{user_data |
          bookmarks: updated_bookmarks,
          folders: updated_folders
        }

        :dets.insert(@table_name, {username, updated_data})
        :dets.sync(@table_name)

        {:reply, :ok, state}
      end
    end
  end

  @impl true
  def handle_call({:move, username, bookmark_id, new_folder}, _from, state) do
    username = sanitize_username(username)
    new_folder = sanitize_folder(new_folder)

    user_data = get_user_data(username)

    if new_folder not in user_data.folders do
      {:reply, {:error, :folder_not_found}, state}
    else
      bookmark = Enum.find(user_data.bookmarks, &(&1.id == bookmark_id))

      if bookmark do
        updated_bookmarks = Enum.map(user_data.bookmarks, fn b ->
          if b.id == bookmark_id, do: %{b | folder: new_folder}, else: b
        end)

        updated_data = %{user_data | bookmarks: updated_bookmarks}
        :dets.insert(@table_name, {username, updated_data})
        :dets.sync(@table_name)

        {:reply, :ok, state}
      else
        {:reply, {:error, :not_found}, state}
      end
    end
  end

  @impl true
  def handle_call({:get, username, bookmark_id}, _from, state) do
    username = sanitize_username(username)
    bookmarks = get_user_bookmarks(username)
    bookmark = Enum.find(bookmarks, &(&1.id == bookmark_id))

    if bookmark do
      {:reply, {:ok, bookmark}, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:count, username}, _from, state) do
    username = sanitize_username(username)
    count = get_bookmark_count(username)
    {:reply, count, state}
  end

  @impl true
  def handle_call({:export, username}, _from, state) do
    username = sanitize_username(username)
    bookmarks = get_user_bookmarks(username)

    export_text = bookmarks
      |> Enum.group_by(& &1.folder)
      |> Enum.map(fn {folder, items} ->
        folder_header = "=== #{folder} ==="
        bookmark_lines = Enum.map(items, fn b ->
          "#{b.title}\n  #{b.selector}"
        end) |> Enum.join("\n")

        "#{folder_header}\n#{bookmark_lines}"
      end)
      |> Enum.join("\n\n")

    {:reply, {:ok, export_text}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = :dets.foldl(fn {_username, data}, acc ->
      %{
        total_users: acc.total_users + 1,
        total_bookmarks: acc.total_bookmarks + length(data.bookmarks),
        total_folders: acc.total_folders + length(data.folders)
      }
    end, %{total_users: 0, total_bookmarks: 0, total_folders: 0}, @table_name)

    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp get_user_data(username) do
    case :dets.lookup(@table_name, username) do
      [{^username, data}] -> data
      [] -> %{bookmarks: [], folders: ["default"]}
    end
  end

  defp get_user_bookmarks(username) do
    get_user_data(username).bookmarks
  end

  defp get_bookmark_count(username) do
    length(get_user_bookmarks(username))
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp sanitize_username(username) do
    username
    |> String.trim()
    |> String.downcase()
    |> String.slice(0, 30)
    |> String.replace(~r/[^\w\d_-]/, "")
  end

  defp sanitize_folder(folder) do
    folder
    |> String.trim()
    |> String.slice(0, 30)
    |> String.replace(~r/[^\w\d_\s-]/, "")
    |> then(fn f -> if f == "", do: "default", else: f end)
  end

  defp sanitize_title(title) do
    title
    |> String.trim()
    |> String.slice(0, 100)
    |> String.replace(~r/[\r\n\t]/, " ")
  end
end
