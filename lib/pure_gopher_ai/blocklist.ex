defmodule PureGopherAi.Blocklist do
  @moduledoc """
  External IP blocklist integration.
  Fetches and caches blocklists from public sources like floodgap and sdf.org.
  """

  use GenServer
  require Logger

  @table_name :blocklist
  @default_refresh_interval 3_600_000  # Refresh every hour
  @default_sources [
    # Floodgap maintains a Gopher abuse blocklist
    {"floodgap", "https://gopher.floodgap.com/gopher/blocklist.txt"},
    # Add more sources as needed
  ]

  # Client API

  @doc """
  Starts the blocklist GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if an IP is in any blocklist.
  """
  def blocked?(ip) when is_tuple(ip) do
    blocked?(format_ip(ip))
  end

  def blocked?(ip) when is_binary(ip) do
    if enabled?() do
      case :ets.lookup(@table_name, ip) do
        [{^ip, _source}] -> true
        [] -> check_cidr(ip)
      end
    else
      false
    end
  end

  @doc """
  Returns blocklist statistics.
  """
  def stats do
    size = :ets.info(@table_name, :size) || 0
    sources = Application.get_env(:pure_gopher_ai, :blocklist_sources, @default_sources)

    %{
      enabled: enabled?(),
      total_blocked: size,
      sources: length(sources),
      refresh_interval_hours: div(refresh_interval(), 3_600_000)
    }
  end

  @doc """
  Forces a refresh of all blocklists.
  """
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc """
  Checks if blocklist is enabled.
  """
  def enabled? do
    Application.get_env(:pure_gopher_ai, :blocklist_enabled, false)
  end

  @doc """
  Gets the refresh interval in milliseconds.
  """
  def refresh_interval do
    Application.get_env(:pure_gopher_ai, :blocklist_refresh_ms, @default_refresh_interval)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set])

    if enabled?() do
      # Initial fetch
      send(self(), :refresh)
      Logger.info("Blocklist started, refresh interval: #{div(refresh_interval(), 60_000)} min")
    else
      Logger.info("Blocklist disabled")
    end

    {:ok, %{last_refresh: nil}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    do_refresh()
    schedule_refresh()
    {:noreply, %{state | last_refresh: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:refresh, state) do
    do_refresh()
    schedule_refresh()
    {:noreply, %{state | last_refresh: DateTime.utc_now()}}
  end

  # Private functions

  defp schedule_refresh do
    if enabled?() do
      Process.send_after(self(), :refresh, refresh_interval())
    end
  end

  defp do_refresh do
    sources = Application.get_env(:pure_gopher_ai, :blocklist_sources, @default_sources)

    # Clear existing entries
    :ets.delete_all_objects(@table_name)

    # Fetch from each source
    total =
      sources
      |> Enum.map(fn {name, url} ->
        case fetch_blocklist(url) do
          {:ok, ips} ->
            Enum.each(ips, fn ip ->
              :ets.insert(@table_name, {ip, name})
            end)
            Logger.info("Blocklist: loaded #{length(ips)} IPs from #{name}")
            length(ips)

          {:error, reason} ->
            Logger.warning("Blocklist: failed to fetch from #{name}: #{inspect(reason)}")
            0
        end
      end)
      |> Enum.sum()

    # Also load local blocklist file if exists
    local_count = load_local_blocklist()

    Logger.info("Blocklist: total #{total + local_count} IPs loaded")
  end

  defp fetch_blocklist(url) do
    # Use httpc from :inets for simple HTTP GET
    :inets.start()
    :ssl.start()

    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, []}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        ips =
          body
          |> List.to_string()
          |> parse_blocklist()

        {:ok, ips}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp parse_blocklist(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line ->
      line == "" or String.starts_with?(line, "#")
    end)
    |> Enum.filter(&valid_ip?/1)
  end

  defp valid_ip?(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, _} -> true
      _ -> String.contains?(ip_string, "/")  # CIDR notation
    end
  end

  defp load_local_blocklist do
    local_file = Application.get_env(:pure_gopher_ai, :blocklist_file, "~/.gopher/blocklist.txt")
    expanded = Path.expand(local_file)

    if File.exists?(expanded) do
      case File.read(expanded) do
        {:ok, content} ->
          ips = parse_blocklist(content)
          Enum.each(ips, fn ip ->
            :ets.insert(@table_name, {ip, "local"})
          end)
          Logger.info("Blocklist: loaded #{length(ips)} IPs from local file")
          length(ips)

        {:error, reason} ->
          Logger.warning("Blocklist: failed to read local file: #{inspect(reason)}")
          0
      end
    else
      0
    end
  end

  defp check_cidr(ip) do
    # Check if IP matches any CIDR blocks in the blocklist
    # For now, simple exact match only
    # TODO: Implement proper CIDR matching
    false
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip) when is_binary(ip), do: ip
end
