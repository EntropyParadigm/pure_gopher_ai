defmodule PureGopherAi.Guestbook do
  @moduledoc """
  Guestbook for PureGopherAI.

  A classic Gopher guestbook allowing visitors to leave messages.
  Entries are persisted to disk using DETS.

  Features:
  - Persistent storage (survives restarts)
  - Rate limiting per IP
  - Pagination
  - Admin moderation
  - Optional AI sentiment analysis
  """

  use GenServer
  require Logger

  @table_name :guestbook
  @default_max_entries 1000
  @default_entries_per_page 20
  @sign_cooldown_ms 300_000  # 5 minutes between signatures per IP

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets all guestbook entries, newest first.
  """
  def list_entries(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, @default_entries_per_page)

    GenServer.call(__MODULE__, {:list_entries, page, per_page})
  end

  @doc """
  Signs the guestbook with a new entry.
  """
  def sign(name, message, client_ip) do
    GenServer.call(__MODULE__, {:sign, name, message, client_ip})
  end

  @doc """
  Gets a single entry by ID.
  """
  def get_entry(id) do
    GenServer.call(__MODULE__, {:get_entry, id})
  end

  @doc """
  Deletes an entry (admin only).
  """
  def delete_entry(id) do
    GenServer.call(__MODULE__, {:delete_entry, id})
  end

  @doc """
  Gets guestbook statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Checks if an IP can sign (rate limiting).
  """
  def can_sign?(client_ip) do
    GenServer.call(__MODULE__, {:can_sign?, client_ip})
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    # Ensure data directory exists
    data_dir = data_directory()
    File.mkdir_p!(data_dir)

    # Open DETS table for persistent storage
    dets_file = Path.join(data_dir, "guestbook.dets") |> String.to_charlist()

    case :dets.open_file(@table_name, file: dets_file, type: :set) do
      {:ok, _} ->
        Logger.info("[Guestbook] Loaded from #{dets_file}")

        # ETS for rate limiting (in-memory only)
        :ets.new(:guestbook_ratelimit, [:set, :named_table, :public])

        {:ok, %{max_entries: max_entries()}}

      {:error, reason} ->
        Logger.error("[Guestbook] Failed to open DETS: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:list_entries, page, per_page}, _from, state) do
    entries = :dets.foldl(
      fn {_id, entry}, acc -> [entry | acc] end,
      [],
      @table_name
    )

    # Sort by timestamp, newest first
    sorted = Enum.sort_by(entries, & &1.timestamp, {:desc, DateTime})

    # Paginate
    total = length(sorted)
    total_pages = max(1, ceil(total / per_page))
    offset = (page - 1) * per_page

    page_entries = sorted
      |> Enum.drop(offset)
      |> Enum.take(per_page)

    result = %{
      entries: page_entries,
      page: page,
      per_page: per_page,
      total: total,
      total_pages: total_pages
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call({:sign, name, message, client_ip}, _from, state) do
    # Check rate limit
    ip_key = format_ip(client_ip)

    case check_rate_limit(ip_key) do
      :ok ->
        # Sanitize inputs
        name = sanitize_input(name, 50)
        message = sanitize_input(message, 500)

        if String.length(name) < 1 or String.length(message) < 1 do
          {:reply, {:error, :invalid_input}, state}
        else
          # Generate entry
          id = generate_id()
          timestamp = DateTime.utc_now()

          entry = %{
            id: id,
            name: name,
            message: message,
            timestamp: timestamp,
            ip_hash: hash_ip(client_ip)
          }

          # Store entry
          :dets.insert(@table_name, {id, entry})
          :dets.sync(@table_name)

          # Update rate limit
          :ets.insert(:guestbook_ratelimit, {ip_key, System.monotonic_time(:millisecond)})

          # Prune old entries if over limit
          prune_entries(state.max_entries)

          Logger.info("[Guestbook] New entry from #{ip_key}: #{name}")
          {:reply, {:ok, entry}, state}
        end

      {:error, :rate_limited, retry_after} ->
        {:reply, {:error, :rate_limited, retry_after}, state}
    end
  end

  @impl true
  def handle_call({:get_entry, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, entry}] -> {:reply, {:ok, entry}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_entry, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, _entry}] ->
        :dets.delete(@table_name, id)
        :dets.sync(@table_name)
        Logger.info("[Guestbook] Deleted entry: #{id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total = :dets.info(@table_name, :size)

    # Get date range
    entries = :dets.foldl(
      fn {_id, entry}, acc -> [entry.timestamp | acc] end,
      [],
      @table_name
    )

    {oldest, newest} = if entries == [] do
      {nil, nil}
    else
      sorted = Enum.sort(entries, DateTime)
      {List.first(sorted), List.last(sorted)}
    end

    stats = %{
      total_entries: total,
      max_entries: state.max_entries,
      oldest_entry: oldest,
      newest_entry: newest
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:can_sign?, client_ip}, _from, state) do
    ip_key = format_ip(client_ip)

    result = case check_rate_limit(ip_key) do
      :ok -> true
      {:error, :rate_limited, _} -> false
    end

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp data_directory do
    Application.get_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
    |> Path.expand()
  end

  defp max_entries do
    Application.get_env(:pure_gopher_ai, :guestbook_max_entries, @default_max_entries)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp hash_ip(ip) do
    :crypto.hash(:sha256, format_ip(ip))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip), do: inspect(ip)

  defp sanitize_input(text, max_length) do
    text
    |> String.trim()
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")  # Remove control characters
    |> String.slice(0, max_length)
  end

  defp check_rate_limit(ip_key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(:guestbook_ratelimit, ip_key) do
      [{^ip_key, last_sign}] ->
        elapsed = now - last_sign

        if elapsed >= @sign_cooldown_ms do
          :ok
        else
          retry_after = @sign_cooldown_ms - elapsed
          {:error, :rate_limited, retry_after}
        end

      [] ->
        :ok
    end
  end

  defp prune_entries(max_entries) do
    current_count = :dets.info(@table_name, :size)

    if current_count > max_entries do
      # Get all entries sorted by timestamp (oldest first)
      entries = :dets.foldl(
        fn {id, entry}, acc -> [{id, entry.timestamp} | acc] end,
        [],
        @table_name
      )

      to_delete = entries
        |> Enum.sort_by(fn {_id, ts} -> ts end, DateTime)
        |> Enum.take(current_count - max_entries)

      Enum.each(to_delete, fn {id, _ts} ->
        :dets.delete(@table_name, id)
      end)

      :dets.sync(@table_name)
      Logger.info("[Guestbook] Pruned #{length(to_delete)} old entries")
    end
  end
end
