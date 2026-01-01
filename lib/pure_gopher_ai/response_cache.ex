defmodule PureGopherAi.ResponseCache do
  @moduledoc """
  Caches AI responses to reduce GPU load for repeated queries.
  Uses ETS with TTL-based expiration and LRU eviction.

  Cache keys are hashes of: query + model/persona + context (if any)

  Configurable via:
  - :cache_enabled - Enable/disable caching (default: true)
  - :cache_ttl_ms - Cache entry TTL in ms (default: 3600000 = 1 hour)
  - :cache_max_entries - Max entries before LRU eviction (default: 1000)
  """

  use GenServer
  require Logger

  @table_name :response_cache
  @stats_table :response_cache_stats
  @cleanup_interval 300_000  # Clean up expired entries every 5 minutes

  # Client API

  @doc """
  Starts the response cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a cached response for the given query parameters.
  Returns {:ok, response} if found, :miss if not cached.
  """
  def get(query, opts \\ []) do
    if enabled?() do
      key = cache_key(query, opts)

      case :ets.lookup(@table_name, key) do
        [{^key, response, inserted_at, _last_accessed}] ->
          # Check if expired
          if expired?(inserted_at) do
            :ets.delete(@table_name, key)
            increment_stat(:misses)
            :miss
          else
            # Update last accessed time for LRU
            :ets.update_element(@table_name, key, {4, System.monotonic_time(:millisecond)})
            increment_stat(:hits)
            {:ok, response}
          end

        [] ->
          increment_stat(:misses)
          :miss
      end
    else
      :miss
    end
  end

  @doc """
  Stores a response in the cache.
  """
  def put(query, response, opts \\ []) do
    if enabled?() do
      key = cache_key(query, opts)
      now = System.monotonic_time(:millisecond)

      # Check if we need to evict before inserting
      maybe_evict()

      :ets.insert(@table_name, {key, response, now, now})
      increment_stat(:writes)
      :ok
    else
      :ok
    end
  end

  @doc """
  Clears the entire cache.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    reset_stats()
    :ok
  end

  @doc """
  Gets cache statistics.
  """
  def stats do
    hits = get_stat(:hits)
    misses = get_stat(:misses)
    writes = get_stat(:writes)
    size = :ets.info(@table_name, :size)

    hit_rate =
      if hits + misses > 0 do
        Float.round(hits / (hits + misses) * 100, 1)
      else
        0.0
      end

    %{
      hits: hits,
      misses: misses,
      writes: writes,
      size: size,
      max_size: max_entries(),
      hit_rate: hit_rate,
      enabled: enabled?()
    }
  end

  @doc """
  Returns true if caching is enabled.
  """
  def enabled? do
    Application.get_env(:pure_gopher_ai, :cache_enabled, true)
  end

  @doc """
  Returns the cache TTL in milliseconds.
  """
  def ttl_ms do
    Application.get_env(:pure_gopher_ai, :cache_ttl_ms, 3_600_000)
  end

  @doc """
  Returns the max number of cache entries.
  """
  def max_entries do
    Application.get_env(:pure_gopher_ai, :cache_max_entries, 1000)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # read_concurrency for high-frequency cache lookups
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@stats_table, [:named_table, :public, :set, read_concurrency: true])

    # Initialize stats
    :ets.insert(@stats_table, {:hits, 0})
    :ets.insert(@stats_table, {:misses, 0})
    :ets.insert(@stats_table, {:writes, 0})

    schedule_cleanup()

    Logger.info("ResponseCache started: TTL #{div(ttl_ms(), 60_000)} min, max #{max_entries()} entries")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp cache_key(query, opts) do
    model = Keyword.get(opts, :model, "default")
    persona = Keyword.get(opts, :persona)
    context = Keyword.get(opts, :context)

    key_data =
      [query, model, persona, context]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("|")

    :crypto.hash(:sha256, key_data)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp expired?(inserted_at) do
    now = System.monotonic_time(:millisecond)
    now - inserted_at > ttl_ms()
  end

  defp maybe_evict do
    size = :ets.info(@table_name, :size)
    max = max_entries()

    if size >= max do
      # Evict oldest 10% by last_accessed time
      evict_count = max(div(max, 10), 1)
      evict_lru(evict_count)
    end
  end

  defp evict_lru(count) do
    # Get all entries sorted by last_accessed (oldest first)
    entries =
      :ets.tab2list(@table_name)
      |> Enum.sort_by(fn {_key, _response, _inserted, last_accessed} -> last_accessed end)
      |> Enum.take(count)

    # Delete the oldest entries
    Enum.each(entries, fn {key, _, _, _} ->
      :ets.delete(@table_name, key)
    end)

    if count > 0 do
      Logger.debug("ResponseCache: evicted #{count} LRU entries")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)
    ttl = ttl_ms()
    cutoff = now - ttl

    expired_count =
      :ets.foldl(
        fn {key, _response, inserted_at, _last_accessed}, count ->
          if inserted_at < cutoff do
            :ets.delete(@table_name, key)
            count + 1
          else
            count
          end
        end,
        0,
        @table_name
      )

    if expired_count > 0 do
      Logger.debug("ResponseCache: cleaned up #{expired_count} expired entries")
    end
  end

  defp increment_stat(stat) do
    :ets.update_counter(@stats_table, stat, 1)
  rescue
    _ -> :ok
  end

  defp get_stat(stat) do
    case :ets.lookup(@stats_table, stat) do
      [{^stat, value}] -> value
      [] -> 0
    end
  end

  defp reset_stats do
    :ets.insert(@stats_table, {:hits, 0})
    :ets.insert(@stats_table, {:misses, 0})
    :ets.insert(@stats_table, {:writes, 0})
  end
end
