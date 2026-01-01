defmodule PureGopherAi.Tags do
  @moduledoc """
  Tagging system for content discovery.

  Features:
  - Add/remove tags on content
  - Browse content by tag
  - Tag cloud with popularity
  - Suggested tags based on content
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserProfiles

  @table_name :tags
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_tags_per_item 10
  @max_tag_length 30
  @min_tag_length 2

  # Content types that can be tagged
  @content_types [:phlog, :bulletin, :document]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds tags to content. Only content owner can tag.
  Tags should be a list of strings.
  """
  def add_tags(username, passphrase, content_type, content_id, tags) when is_list(tags) do
    GenServer.call(__MODULE__, {:add_tags, username, passphrase, content_type, content_id, tags})
  end

  @doc """
  Removes tags from content.
  """
  def remove_tags(username, passphrase, content_type, content_id, tags) when is_list(tags) do
    GenServer.call(__MODULE__, {:remove_tags, username, passphrase, content_type, content_id, tags})
  end

  @doc """
  Sets all tags for content (replaces existing).
  """
  def set_tags(username, passphrase, content_type, content_id, tags) when is_list(tags) do
    GenServer.call(__MODULE__, {:set_tags, username, passphrase, content_type, content_id, tags})
  end

  @doc """
  Gets tags for a specific content item.
  """
  def get_tags(content_type, content_id) do
    GenServer.call(__MODULE__, {:get_tags, content_type, content_id})
  end

  @doc """
  Gets all content with a specific tag.
  """
  def get_by_tag(tag, opts \\ []) do
    GenServer.call(__MODULE__, {:get_by_tag, tag, opts})
  end

  @doc """
  Gets a tag cloud (tags with counts).
  """
  def tag_cloud(opts \\ []) do
    GenServer.call(__MODULE__, {:tag_cloud, opts})
  end

  @doc """
  Gets related tags (tags that often appear together).
  """
  def related_tags(tag, opts \\ []) do
    GenServer.call(__MODULE__, {:related_tags, tag, opts})
  end

  @doc """
  Searches tags by prefix.
  """
  def search_tags(prefix, opts \\ []) do
    GenServer.call(__MODULE__, {:search_tags, prefix, opts})
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

    dets_file = Path.join(data_dir, "tags.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    Logger.info("[Tags] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_tags, username, passphrase, content_type, content_id, new_tags}, _from, state) do
    if content_type not in @content_types do
      {:reply, {:error, :invalid_content_type}, state}
    else
      case UserProfiles.authenticate(username, passphrase) do
        {:ok, _profile} ->
          username_lower = String.downcase(String.trim(username))
          key = {content_type, content_id}

          # Get existing tags
          existing = case :dets.lookup(@table_name, key) do
            [{^key, data}] -> data.tags
            [] -> []
          end

          # Normalize and validate new tags
          normalized = normalize_tags(new_tags)
          combined = (existing ++ normalized) |> Enum.uniq() |> Enum.take(@max_tags_per_item)

          now = DateTime.utc_now() |> DateTime.to_iso8601()

          tag_data = %{
            content_type: content_type,
            content_id: content_id,
            owner: username_lower,
            tags: combined,
            created_at: now,
            updated_at: now
          }

          :dets.insert(@table_name, {key, tag_data})
          :dets.sync(@table_name)

          {:reply, {:ok, combined}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:remove_tags, username, passphrase, content_type, content_id, tags_to_remove}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        key = {content_type, content_id}

        case :dets.lookup(@table_name, key) do
          [{^key, data}] ->
            normalized_remove = normalize_tags(tags_to_remove)
            remaining = Enum.reject(data.tags, &(&1 in normalized_remove))

            updated = %{data |
              tags: remaining,
              updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }

            :dets.insert(@table_name, {key, updated})
            :dets.sync(@table_name)

            {:reply, {:ok, remaining}, state}

          [] ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_tags, username, passphrase, content_type, content_id, tags}, _from, state) do
    if content_type not in @content_types do
      {:reply, {:error, :invalid_content_type}, state}
    else
      case UserProfiles.authenticate(username, passphrase) do
        {:ok, _profile} ->
          username_lower = String.downcase(String.trim(username))
          key = {content_type, content_id}

          normalized = normalize_tags(tags) |> Enum.take(@max_tags_per_item)
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          tag_data = %{
            content_type: content_type,
            content_id: content_id,
            owner: username_lower,
            tags: normalized,
            created_at: now,
            updated_at: now
          }

          :dets.insert(@table_name, {key, tag_data})
          :dets.sync(@table_name)

          {:reply, {:ok, normalized}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:get_tags, content_type, content_id}, _from, state) do
    key = {content_type, content_id}

    tags = case :dets.lookup(@table_name, key) do
      [{^key, data}] -> data.tags
      [] -> []
    end

    {:reply, {:ok, tags}, state}
  end

  @impl true
  def handle_call({:get_by_tag, tag, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    content_type = Keyword.get(opts, :type)
    normalized_tag = normalize_tag(tag)

    results = :dets.foldl(fn {_key, data}, acc ->
      type_match = is_nil(content_type) or data.content_type == content_type

      if type_match and normalized_tag in data.tags do
        [%{
          content_type: data.content_type,
          content_id: data.content_id,
          tags: data.tags
        } | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.take(limit)

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:tag_cloud, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    content_type = Keyword.get(opts, :type)

    # Count tag occurrences
    counts = :dets.foldl(fn {_key, data}, acc ->
      type_match = is_nil(content_type) or data.content_type == content_type

      if type_match do
        Enum.reduce(data.tags, acc, fn tag, inner_acc ->
          Map.update(inner_acc, tag, 1, &(&1 + 1))
        end)
      else
        acc
      end
    end, %{}, @table_name)

    cloud = counts
      |> Enum.sort_by(fn {_tag, count} -> -count end)
      |> Enum.take(limit)
      |> Enum.map(fn {tag, count} -> %{tag: tag, count: count} end)

    {:reply, {:ok, cloud}, state}
  end

  @impl true
  def handle_call({:related_tags, tag, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    normalized_tag = normalize_tag(tag)

    # Find items with this tag and count co-occurring tags
    co_occurrences = :dets.foldl(fn {_key, data}, acc ->
      if normalized_tag in data.tags do
        other_tags = Enum.reject(data.tags, &(&1 == normalized_tag))
        Enum.reduce(other_tags, acc, fn t, inner_acc ->
          Map.update(inner_acc, t, 1, &(&1 + 1))
        end)
      else
        acc
      end
    end, %{}, @table_name)

    related = co_occurrences
      |> Enum.sort_by(fn {_tag, count} -> -count end)
      |> Enum.take(limit)
      |> Enum.map(fn {t, count} -> %{tag: t, count: count} end)

    {:reply, {:ok, related}, state}
  end

  @impl true
  def handle_call({:search_tags, prefix, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    normalized_prefix = normalize_tag(prefix)

    # Find all unique tags matching prefix
    all_tags = :dets.foldl(fn {_key, data}, acc ->
      matching = Enum.filter(data.tags, &String.starts_with?(&1, normalized_prefix))
      MapSet.union(acc, MapSet.new(matching))
    end, MapSet.new(), @table_name)

    results = all_tags
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.take(limit)

    {:reply, {:ok, results}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&normalize_tag/1)
    |> Enum.filter(&valid_tag?/1)
    |> Enum.uniq()
  end

  defp normalize_tag(tag) when is_binary(tag) do
    tag
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9\-_]/, "")
    |> String.slice(0, @max_tag_length)
  end

  defp normalize_tag(_), do: ""

  defp valid_tag?(tag) do
    len = String.length(tag)
    len >= @min_tag_length and len <= @max_tag_length
  end
end
