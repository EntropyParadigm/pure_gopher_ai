defmodule PureGopherAi.Versioning do
  @moduledoc """
  Content versioning system for tracking edit history.

  Features:
  - Store versions of content on edit
  - View edit history
  - Compare versions
  - Restore previous versions
  """

  use GenServer
  require Logger

  @table_name :versions
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_versions_per_item 50

  # Content types that support versioning
  @content_types [:phlog, :bulletin, :document, :profile]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Saves a new version of content.
  Called automatically when content is edited.
  """
  def save_version(content_type, content_id, author, title, body, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:save, content_type, content_id, author, title, body, metadata})
  end

  @doc """
  Gets all versions of content (newest first).
  """
  def get_versions(content_type, content_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_versions, content_type, content_id, opts})
  end

  @doc """
  Gets a specific version by version number.
  """
  def get_version(content_type, content_id, version_number) do
    GenServer.call(__MODULE__, {:get_version, content_type, content_id, version_number})
  end

  @doc """
  Gets the diff between two versions.
  """
  def diff(content_type, content_id, version_a, version_b) do
    GenServer.call(__MODULE__, {:diff, content_type, content_id, version_a, version_b})
  end

  @doc """
  Gets the current version number for content.
  """
  def current_version(content_type, content_id) do
    GenServer.call(__MODULE__, {:current_version, content_type, content_id})
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

    dets_file = Path.join(data_dir, "versions.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    Logger.info("[Versioning] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:save, content_type, content_id, author, title, body, metadata}, _from, state) do
    if content_type not in @content_types do
      {:reply, {:error, :invalid_content_type}, state}
    else
      key = {content_type, content_id}

      # Get current version number
      versions = get_versions_internal(content_type, content_id)
      version_number = length(versions) + 1

      # Check if we need to prune old versions
      versions_to_keep = if length(versions) >= @max_versions_per_item do
        Enum.take(versions, @max_versions_per_item - 1)
      else
        versions
      end

      now = DateTime.utc_now() |> DateTime.to_iso8601()

      new_version = %{
        version: version_number,
        content_type: content_type,
        content_id: content_id,
        author: author,
        title: title,
        body: body,
        metadata: metadata,
        created_at: now,
        # Store a hash for quick change detection
        content_hash: hash_content(title, body)
      }

      # Store all versions for this content item
      all_versions = [new_version | versions_to_keep]
      :dets.insert(@table_name, {key, all_versions})
      :dets.sync(@table_name)

      Logger.debug("[Versioning] Saved version #{version_number} for #{content_type}/#{content_id}")
      {:reply, {:ok, version_number}, state}
    end
  end

  @impl true
  def handle_call({:get_versions, content_type, content_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    versions = get_versions_internal(content_type, content_id)
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(&summarize_version/1)

    {:reply, {:ok, versions}, state}
  end

  @impl true
  def handle_call({:get_version, content_type, content_id, version_number}, _from, state) do
    versions = get_versions_internal(content_type, content_id)

    case Enum.find(versions, &(&1.version == version_number)) do
      nil -> {:reply, {:error, :version_not_found}, state}
      version -> {:reply, {:ok, version}, state}
    end
  end

  @impl true
  def handle_call({:diff, content_type, content_id, version_a, version_b}, _from, state) do
    versions = get_versions_internal(content_type, content_id)

    with {:ok, v_a} <- find_version(versions, version_a),
         {:ok, v_b} <- find_version(versions, version_b) do

      diff = compute_diff(v_a, v_b)
      {:reply, {:ok, diff}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:current_version, content_type, content_id}, _from, state) do
    versions = get_versions_internal(content_type, content_id)

    version_number = case versions do
      [latest | _] -> latest.version
      [] -> 0
    end

    {:reply, version_number, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp get_versions_internal(content_type, content_id) do
    key = {content_type, content_id}

    case :dets.lookup(@table_name, key) do
      [{^key, versions}] -> versions
      [] -> []
    end
  end

  defp find_version(versions, version_number) do
    case Enum.find(versions, &(&1.version == version_number)) do
      nil -> {:error, :version_not_found}
      version -> {:ok, version}
    end
  end

  defp summarize_version(version) do
    %{
      version: version.version,
      author: version.author,
      title: version.title,
      created_at: version.created_at,
      # Include body length for UI
      body_length: String.length(version.body)
    }
  end

  defp hash_content(title, body) do
    :crypto.hash(:md5, "#{title}\n#{body}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  defp compute_diff(version_a, version_b) do
    title_diff = compute_line_diff(version_a.title, version_b.title)
    body_diff = compute_line_diff(version_a.body, version_b.body)

    %{
      from_version: version_a.version,
      to_version: version_b.version,
      from_date: version_a.created_at,
      to_date: version_b.created_at,
      title_changed: version_a.title != version_b.title,
      title_diff: title_diff,
      body_diff: body_diff,
      stats: compute_stats(version_a.body, version_b.body)
    }
  end

  defp compute_line_diff(text_a, text_b) do
    lines_a = String.split(text_a, "\n")
    lines_b = String.split(text_b, "\n")

    # Simple line-by-line diff
    # For a production system, you'd want a proper diff algorithm (LCS)
    max_lines = max(length(lines_a), length(lines_b))

    Enum.map(0..(max_lines - 1), fn i ->
      line_a = Enum.at(lines_a, i)
      line_b = Enum.at(lines_b, i)

      cond do
        is_nil(line_a) -> {:added, line_b}
        is_nil(line_b) -> {:removed, line_a}
        line_a == line_b -> {:unchanged, line_a}
        true -> {:changed, line_a, line_b}
      end
    end)
    |> Enum.reject(fn
      {:unchanged, _} -> true
      _ -> false
    end)
  end

  defp compute_stats(text_a, text_b) do
    words_a = count_words(text_a)
    words_b = count_words(text_b)
    chars_a = String.length(text_a)
    chars_b = String.length(text_b)

    %{
      words_added: max(0, words_b - words_a),
      words_removed: max(0, words_a - words_b),
      chars_added: max(0, chars_b - chars_a),
      chars_removed: max(0, chars_a - chars_b)
    }
  end

  defp count_words(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
