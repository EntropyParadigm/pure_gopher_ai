defmodule PureGopherAi.Pastebin do
  @moduledoc """
  Simple pastebin for sharing text snippets via Gopher.

  Features:
  - Create text pastes with optional titles
  - Automatic expiration (configurable TTL)
  - Syntax highlighting hints
  - Rate limiting per IP
  - View count tracking
  - Raw text access
  """

  use GenServer
  require Logger

  @table_name :pastebin
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @default_ttl_hours 24 * 7  # 1 week default
  @max_paste_size 50_000     # 50KB max
  @max_title_length 100
  @cleanup_interval 3600_000  # Clean expired pastes every hour

  @syntax_types ~w(text elixir python javascript ruby go rust c cpp java html css sql bash shell markdown json xml yaml)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new paste.

  Options:
  - `:title` - Optional title
  - `:syntax` - Syntax type for highlighting hints
  - `:ttl_hours` - Hours until expiration (default: 168 = 1 week)
  - `:unlisted` - If true, won't appear in recent list
  """
  def create(content, ip, opts \\ []) do
    GenServer.call(__MODULE__, {:create, content, ip, opts})
  end

  @doc """
  Gets a paste by ID.
  """
  def get(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc """
  Gets raw paste content (just the text).
  """
  def get_raw(id) do
    case get(id) do
      {:ok, paste} -> {:ok, paste.content}
      error -> error
    end
  end

  @doc """
  Lists recent pastes (non-unlisted only).
  """
  def list_recent(limit \\ 20) do
    GenServer.call(__MODULE__, {:list_recent, limit})
  end

  @doc """
  Deletes a paste (admin only).
  """
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @doc """
  Gets pastebin statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Returns list of supported syntax types.
  """
  def syntax_types, do: @syntax_types

  @doc """
  Returns max paste size in bytes.
  """
  def max_size, do: @max_paste_size

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "pastebin.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Schedule cleanup
    schedule_cleanup()

    Logger.info("[Pastebin] Started, max size: #{@max_paste_size} bytes")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, content, ip, opts}, _from, state) do
    cond do
      byte_size(content) > @max_paste_size ->
        {:reply, {:error, :too_large}, state}

      String.trim(content) == "" ->
        {:reply, {:error, :empty_content}, state}

      true ->
        id = generate_id()
        now = DateTime.utc_now()
        ttl_hours = Keyword.get(opts, :ttl_hours, @default_ttl_hours)
        expires_at = DateTime.add(now, ttl_hours * 3600, :second)

        title = opts
          |> Keyword.get(:title, "")
          |> String.slice(0, @max_title_length)
          |> String.trim()

        syntax = Keyword.get(opts, :syntax, "text")
        syntax = if syntax in @syntax_types, do: syntax, else: "text"

        paste = %{
          id: id,
          title: if(title == "", do: nil, else: title),
          content: content,
          syntax: syntax,
          size: byte_size(content),
          lines: length(String.split(content, "\n")),
          created_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at),
          ip_hash: hash_ip(ip),
          views: 0,
          unlisted: Keyword.get(opts, :unlisted, false)
        }

        :dets.insert(@table_name, {id, paste})
        :dets.sync(@table_name)

        Logger.info("[Pastebin] Created paste #{id} (#{paste.size} bytes, expires #{expires_at})")
        {:reply, {:ok, id}, state}
    end
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, paste}] ->
        # Check expiration
        case DateTime.from_iso8601(paste.expires_at) do
          {:ok, expires_at, _} ->
            if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
              # Expired, delete it
              :dets.delete(@table_name, id)
              {:reply, {:error, :expired}, state}
            else
              # Increment view count
              updated_paste = %{paste | views: paste.views + 1}
              :dets.insert(@table_name, {id, updated_paste})
              {:reply, {:ok, updated_paste}, state}
            end

          _ ->
            {:reply, {:ok, paste}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_recent, limit}, _from, state) do
    now = DateTime.utc_now()

    pastes = :dets.foldl(fn {_id, paste}, acc ->
      # Filter out unlisted and expired
      with false <- paste.unlisted,
           {:ok, expires_at, _} <- DateTime.from_iso8601(paste.expires_at),
           :gt <- DateTime.compare(expires_at, now) do
        [paste | acc]
      else
        _ -> acc
      end
    end, [], @table_name)

    recent = pastes
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn p ->
        # Don't include full content in list
        Map.drop(p, [:content, :ip_hash])
      end)

    {:reply, {:ok, recent}, state}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, _}] ->
        :dets.delete(@table_name, id)
        :dets.sync(@table_name)
        Logger.info("[Pastebin] Deleted paste #{id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    now = DateTime.utc_now()

    {total, active, total_size, total_views} =
      :dets.foldl(fn {_id, paste}, {t, a, s, v} ->
        is_active = case DateTime.from_iso8601(paste.expires_at) do
          {:ok, exp, _} -> DateTime.compare(exp, now) == :gt
          _ -> true
        end

        {t + 1, a + (if is_active, do: 1, else: 0), s + paste.size, v + paste.views}
      end, {0, 0, 0, 0}, @table_name)

    {:reply, %{
      total_pastes: total,
      active_pastes: active,
      total_size_bytes: total_size,
      total_views: total_views,
      max_paste_size: @max_paste_size,
      default_ttl_hours: @default_ttl_hours
    }, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end

  defp hash_ip(ip) when is_tuple(ip) do
    ip_str = case ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
    end
    :crypto.hash(:sha256, ip_str) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp hash_ip(_), do: "unknown"

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = DateTime.utc_now()
    deleted = :dets.foldl(fn {id, paste}, count ->
      case DateTime.from_iso8601(paste.expires_at) do
        {:ok, expires_at, _} ->
          if DateTime.compare(now, expires_at) == :gt do
            :dets.delete(@table_name, id)
            count + 1
          else
            count
          end

        _ ->
          count
      end
    end, 0, @table_name)

    if deleted > 0 do
      :dets.sync(@table_name)
      Logger.info("[Pastebin] Cleaned up #{deleted} expired pastes")
    end
  end
end
