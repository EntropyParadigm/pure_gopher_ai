defmodule PureGopherAi.Federation do
  @moduledoc """
  Federation system for connecting to other Gopher servers.

  Features:
  - Peer discovery and management
  - Content aggregation from peers
  - Cross-server user following
  - Federated search
  """

  use GenServer
  require Logger

  alias PureGopherAi.GopherProxy

  @table_name :federation
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @sync_interval_ms 3_600_000  # 1 hour
  @fetch_timeout_ms 10_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a peer server to the federation.
  """
  def add_peer(host, port \\ 70, opts \\ []) do
    GenServer.call(__MODULE__, {:add_peer, host, port, opts})
  end

  @doc """
  Removes a peer from the federation.
  """
  def remove_peer(host) do
    GenServer.call(__MODULE__, {:remove_peer, host})
  end

  @doc """
  Lists all federated peers.
  """
  def list_peers do
    GenServer.call(__MODULE__, :list_peers)
  end

  @doc """
  Gets peer status and health.
  """
  def peer_status(host) do
    GenServer.call(__MODULE__, {:peer_status, host})
  end

  @doc """
  Fetches recent content from a peer.
  """
  def fetch_peer_content(host, selector \\ "/phlog") do
    GenServer.call(__MODULE__, {:fetch_content, host, selector}, 30_000)
  end

  @doc """
  Gets aggregated content from all healthy peers.
  """
  def aggregated_feed(opts \\ []) do
    GenServer.call(__MODULE__, {:aggregated_feed, opts}, 60_000)
  end

  @doc """
  Searches across all federated servers.
  """
  def federated_search(query, opts \\ []) do
    GenServer.call(__MODULE__, {:federated_search, query, opts}, 60_000)
  end

  @doc """
  Pings a peer to check if it's alive.
  """
  def ping_peer(host) do
    GenServer.call(__MODULE__, {:ping, host}, 15_000)
  end

  @doc """
  Forces a sync with all peers.
  """
  def sync_all do
    GenServer.cast(__MODULE__, :sync_all)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "federation.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # ETS for cached content
    :ets.new(:federation_cache, [:named_table, :public, :set])

    # Schedule periodic sync
    :timer.send_interval(@sync_interval_ms, :sync)

    Logger.info("[Federation] Started")
    {:ok, %{syncing: false}}
  end

  @impl true
  def handle_call({:add_peer, host, port, opts}, _from, state) do
    host_lower = String.downcase(String.trim(host))
    name = Keyword.get(opts, :name, host)
    description = Keyword.get(opts, :description, "")

    # Check if peer already exists
    case :dets.lookup(@table_name, host_lower) do
      [{^host_lower, _}] ->
        {:reply, {:error, :peer_exists}, state}

      [] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        peer = %{
          host: host,
          host_lower: host_lower,
          port: port,
          name: name,
          description: description,
          added_at: now,
          last_sync: nil,
          last_success: nil,
          status: :unknown,
          consecutive_failures: 0,
          content_count: 0
        }

        :dets.insert(@table_name, {host_lower, peer})
        :dets.sync(@table_name)

        # Ping the peer
        spawn(fn -> ping_peer_internal(host_lower, host, port) end)

        Logger.info("[Federation] Added peer: #{host}:#{port}")
        {:reply, {:ok, peer}, state}
    end
  end

  @impl true
  def handle_call({:remove_peer, host}, _from, state) do
    host_lower = String.downcase(String.trim(host))

    case :dets.lookup(@table_name, host_lower) do
      [{^host_lower, _}] ->
        :dets.delete(@table_name, host_lower)
        :dets.sync(@table_name)
        # Clear cached content
        :ets.match_delete(:federation_cache, {{host_lower, :_}, :_})
        Logger.info("[Federation] Removed peer: #{host}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :peer_not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_peers, _from, state) do
    peers = :dets.foldl(fn {_key, peer}, acc ->
      [Map.drop(peer, [:host_lower]) | acc]
    end, [], @table_name)
    |> Enum.sort_by(& &1.name)

    {:reply, {:ok, peers}, state}
  end

  @impl true
  def handle_call({:peer_status, host}, _from, state) do
    host_lower = String.downcase(String.trim(host))

    case :dets.lookup(@table_name, host_lower) do
      [{^host_lower, peer}] ->
        {:reply, {:ok, Map.drop(peer, [:host_lower])}, state}

      [] ->
        {:reply, {:error, :peer_not_found}, state}
    end
  end

  @impl true
  def handle_call({:fetch_content, host, selector}, _from, state) do
    host_lower = String.downcase(String.trim(host))

    case :dets.lookup(@table_name, host_lower) do
      [{^host_lower, peer}] ->
        case fetch_from_peer(peer, selector) do
          {:ok, content} ->
            {:reply, {:ok, content}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :peer_not_found}, state}
    end
  end

  @impl true
  def handle_call({:aggregated_feed, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)

    # Get all healthy peers
    peers = :dets.foldl(fn {_key, peer}, acc ->
      if peer.status == :healthy do
        [peer | acc]
      else
        acc
      end
    end, [], @table_name)

    # Check cache first
    cached_items = peers
    |> Enum.flat_map(fn peer ->
      case :ets.lookup(:federation_cache, {peer.host_lower, :phlog}) do
        [{{_, :phlog}, items}] -> items
        [] -> []
      end
    end)

    sorted = cached_items
    |> Enum.sort_by(& &1.date, :desc)
    |> Enum.take(limit)

    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:federated_search, query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)

    # Get all healthy peers
    peers = :dets.foldl(fn {_key, peer}, acc ->
      if peer.status == :healthy do
        [peer | acc]
      else
        acc
      end
    end, [], @table_name)

    # Search each peer (with timeout)
    results = peers
    |> Task.async_stream(fn peer ->
      search_peer(peer, query)
    end, timeout: 10_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, {:ok, items}} -> items
      _ -> []
    end)
    |> Enum.take(limit)

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:ping, host}, _from, state) do
    host_lower = String.downcase(String.trim(host))

    case :dets.lookup(@table_name, host_lower) do
      [{^host_lower, peer}] ->
        result = ping_peer_internal(host_lower, peer.host, peer.port)
        {:reply, result, state}

      [] ->
        {:reply, {:error, :peer_not_found}, state}
    end
  end

  @impl true
  def handle_cast(:sync_all, state) do
    if state.syncing do
      {:noreply, state}
    else
      spawn(fn -> sync_all_peers() end)
      {:noreply, %{state | syncing: true}}
    end
  end

  @impl true
  def handle_info(:sync, state) do
    if not state.syncing do
      spawn(fn -> sync_all_peers() end)
    end
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_complete, state) do
    {:noreply, %{state | syncing: false}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp ping_peer_internal(host_lower, host, port) do
    start_time = System.monotonic_time(:millisecond)

    result = try do
      case GopherProxy.fetch(host, port, "/") do
        {:ok, _content} ->
          latency = System.monotonic_time(:millisecond) - start_time
          update_peer_status(host_lower, :healthy, latency)
          {:ok, %{status: :healthy, latency_ms: latency}}

        {:error, reason} ->
          update_peer_status(host_lower, :unhealthy, nil)
          {:error, reason}
      end
    catch
      _, _ ->
        update_peer_status(host_lower, :unhealthy, nil)
        {:error, :connection_failed}
    end

    result
  end

  defp update_peer_status(host_lower, status, latency) do
    case :dets.lookup(@table_name, host_lower) do
      [{^host_lower, peer}] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated = case status do
          :healthy ->
            %{peer |
              status: :healthy,
              last_success: now,
              last_sync: now,
              consecutive_failures: 0,
              latency_ms: latency
            }

          :unhealthy ->
            %{peer |
              status: if(peer.consecutive_failures >= 3, do: :dead, else: :unhealthy),
              last_sync: now,
              consecutive_failures: peer.consecutive_failures + 1
            }
        end

        :dets.insert(@table_name, {host_lower, updated})
        :dets.sync(@table_name)

      [] ->
        :ok
    end
  end

  defp fetch_from_peer(peer, selector) do
    case GopherProxy.fetch(peer.host, peer.port, selector) do
      {:ok, content} ->
        # Parse gophermap content
        items = parse_gophermap(content, peer)
        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_gophermap(content, peer) do
    content
    |> String.split("\r\n")
    |> Enum.map(&parse_gophermap_line(&1, peer))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_gophermap_line(line, peer) do
    case String.split(line, "\t") do
      [type_and_text, selector, host, port | _] ->
        type = String.first(type_and_text) || "i"
        text = String.slice(type_and_text, 1..-1//1)

        if type in ["0", "1"] do
          %{
            type: type,
            text: text,
            selector: selector,
            host: host,
            port: String.to_integer(port),
            source_peer: peer.host,
            date: extract_date_from_text(text)
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_date_from_text(text) do
    # Try to extract date from common phlog formats like "2024-01-15: Title"
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})/, text) do
      [_, date] -> date
      nil -> nil
    end
  end

  defp search_peer(peer, query) do
    selector = "/search\t#{query}"

    case GopherProxy.fetch(peer.host, peer.port, selector) do
      {:ok, content} ->
        items = parse_gophermap(content, peer)
        {:ok, items}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp sync_all_peers do
    peers = :dets.foldl(fn {_key, peer}, acc ->
      [peer | acc]
    end, [], @table_name)

    Enum.each(peers, fn peer ->
      # Ping and fetch content
      ping_peer_internal(peer.host_lower, peer.host, peer.port)

      case fetch_from_peer(peer, "/phlog") do
        {:ok, items} ->
          # Cache the content
          :ets.insert(:federation_cache, {{peer.host_lower, :phlog}, items})

          # Update content count
          case :dets.lookup(@table_name, peer.host_lower) do
            [{host_lower, p}] ->
              updated = %{p | content_count: length(items)}
              :dets.insert(@table_name, {host_lower, updated})

            [] ->
              :ok
          end

        _ ->
          :ok
      end
    end)

    :dets.sync(@table_name)
    send(__MODULE__, :sync_complete)
  end
end
