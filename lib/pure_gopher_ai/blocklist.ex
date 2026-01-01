defmodule PureGopherAi.Blocklist do
  @moduledoc """
  External IP blocklist integration.
  Fetches and caches blocklists from public sources including:
  - Floodgap's responsible-bot list (via Gopher protocol)
  - FireHOL curated blocklists (via HTTPS)

  Supports both HTTP/HTTPS and Gopher protocol URLs.
  """

  use GenServer
  require Logger
  import Bitwise

  @table_name :blocklist
  @cidr_table :blocklist_cidr
  @default_refresh_interval 3_600_000  # Refresh every hour
  @gopher_timeout 30_000  # 30 second timeout for Gopher fetches
  @default_sources [
    # Floodgap's official Gopher bot blocklist
    {"floodgap", "gopher://gopher.floodgap.com/0/responsible-bot"},
    # FireHOL curated blocklists - well-maintained public lists
    {"firehol_level1", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"},
    {"firehol_abusers_1d", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_abusers_1d.netset"}
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
      # First check exact IP match
      case :ets.lookup(@table_name, ip) do
        [{^ip, _source}] -> true
        [] ->
          # Then check CIDR blocks
          check_cidr_blocks(ip)
      end
    else
      false
    end
  end

  @doc """
  Returns blocklist statistics.
  """
  def stats do
    ip_count = :ets.info(@table_name, :size) || 0
    cidr_count = :ets.info(@cidr_table, :size) || 0
    sources = Application.get_env(:pure_gopher_ai, :blocklist_sources, @default_sources)

    %{
      enabled: enabled?(),
      blocked_ips: ip_count,
      blocked_cidrs: cidr_count,
      total_entries: ip_count + cidr_count,
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
    # read_concurrency for per-request blocklist checks
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@cidr_table, [:named_table, :public, :set, read_concurrency: true])

    if enabled?() do
      # Initial fetch
      send(self(), :refresh)
      sources = Application.get_env(:pure_gopher_ai, :blocklist_sources, @default_sources)
      Logger.info("Blocklist started with #{length(sources)} sources, refresh: #{div(refresh_interval(), 60_000)} min")
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
    :ets.delete_all_objects(@cidr_table)

    # Fetch from each source
    {total_ips, total_cidrs} =
      sources
      |> Enum.map(fn {name, url} ->
        case fetch_blocklist(url) do
          {:ok, {ips, cidrs}} ->
            Enum.each(ips, fn ip ->
              :ets.insert(@table_name, {ip, name})
            end)
            Enum.each(cidrs, fn cidr ->
              :ets.insert(@cidr_table, {cidr, name})
            end)
            Logger.info("Blocklist: loaded #{length(ips)} IPs + #{length(cidrs)} CIDRs from #{name}")
            {length(ips), length(cidrs)}

          {:error, reason} ->
            Logger.warning("Blocklist: failed to fetch from #{name}: #{inspect(reason)}")
            {0, 0}
        end
      end)
      |> Enum.reduce({0, 0}, fn {ips, cidrs}, {acc_ips, acc_cidrs} ->
        {acc_ips + ips, acc_cidrs + cidrs}
      end)

    # Also load local blocklist file if exists
    {local_ips, local_cidrs} = load_local_blocklist()

    Logger.info("Blocklist: total #{total_ips + local_ips} IPs + #{total_cidrs + local_cidrs} CIDRs loaded")
  end

  defp fetch_blocklist(url) do
    cond do
      String.starts_with?(url, "gopher://") ->
        fetch_gopher_blocklist(url)

      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        fetch_http_blocklist(url)

      true ->
        {:error, {:unsupported_protocol, url}}
    end
  rescue
    e -> {:error, e}
  end

  defp fetch_http_blocklist(url) do
    # Use httpc from :inets for simple HTTP GET
    :inets.start()
    :ssl.start()

    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, []}, [{:timeout, 30_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {ips, cidrs} =
          body
          |> List.to_string()
          |> parse_blocklist()

        {:ok, {ips, cidrs}}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_gopher_blocklist(url) do
    # Parse gopher:// URL and fetch
    # Format: gopher://host[:port]/type/selector
    {host, port, selector} = parse_gopher_url(url)
    fetch_gopher_content(host, port, selector)
  end

  defp parse_gopher_url(url) do
    # Remove gopher:// prefix
    rest = String.replace_prefix(url, "gopher://", "")

    # Split host/port from path
    case String.split(rest, "/", parts: 2) do
      [host_port, path] ->
        {host, port} = parse_host_port(host_port)
        # Path format: /type/selector - extract selector (skip type character)
        selector =
          case String.split(path, "/", parts: 2) do
            [_type, sel] -> "/" <> sel
            [_type] -> ""
            [] -> ""
          end

        {host, port, selector}

      [host_port] ->
        {host, port} = parse_host_port(host_port)
        {host, port, ""}
    end
  end

  defp parse_host_port(host_port) do
    case String.split(host_port, ":") do
      [host, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} -> {host, port}
          _ -> {host, 70}
        end

      [host] ->
        {host, 70}
    end
  end

  defp fetch_gopher_content(host, port, selector) do
    # Connect via TCP and send selector
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @gopher_timeout) do
      {:ok, socket} ->
        # Send selector + CRLF
        request = selector <> "\r\n"
        :gen_tcp.send(socket, request)

        # Read response
        result = recv_all(socket, [])
        :gen_tcp.close(socket)

        case result do
          {:ok, data} ->
            {ips, cidrs} = parse_blocklist(data)
            {:ok, {ips, cidrs}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, @gopher_timeout) do
      {:ok, data} ->
        recv_all(socket, [data | acc])

      {:error, :closed} ->
        {:ok, acc |> Enum.reverse() |> Enum.join()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_blocklist(content) do
    entries =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(fn line ->
        line == "" or String.starts_with?(line, "#")
      end)
      |> Enum.filter(&valid_entry?/1)

    # Separate IPs from CIDR blocks
    {ips, cidrs} =
      Enum.split_with(entries, fn entry ->
        not String.contains?(entry, "/")
      end)

    {ips, cidrs}
  end

  defp valid_entry?(entry) do
    cond do
      String.contains?(entry, "/") ->
        # CIDR notation - validate format
        case String.split(entry, "/") do
          [ip_part, mask] ->
            valid_ip?(ip_part) and valid_mask?(mask)
          _ ->
            false
        end

      true ->
        # Plain IP
        valid_ip?(entry)
    end
  end

  defp valid_ip?(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_mask?(mask) do
    case Integer.parse(mask) do
      {n, ""} when n >= 0 and n <= 128 -> true
      _ -> false
    end
  end

  defp load_local_blocklist do
    local_file = Application.get_env(:pure_gopher_ai, :blocklist_file, "~/.gopher/blocklist.txt")
    expanded = Path.expand(local_file)

    if File.exists?(expanded) do
      case File.read(expanded) do
        {:ok, content} ->
          {ips, cidrs} = parse_blocklist(content)

          Enum.each(ips, fn ip ->
            :ets.insert(@table_name, {ip, "local"})
          end)
          Enum.each(cidrs, fn cidr ->
            :ets.insert(@cidr_table, {cidr, "local"})
          end)

          Logger.info("Blocklist: loaded #{length(ips)} IPs + #{length(cidrs)} CIDRs from local file")
          {length(ips), length(cidrs)}

        {:error, reason} ->
          Logger.warning("Blocklist: failed to read local file: #{inspect(reason)}")
          {0, 0}
      end
    else
      {0, 0}
    end
  end

  defp check_cidr_blocks(ip_string) do
    # Parse the IP to check
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} ->
        # Check against all CIDR blocks
        :ets.foldl(
          fn {cidr, _source}, acc ->
            if acc do
              acc
            else
              ip_in_cidr?(ip_tuple, cidr)
            end
          end,
          false,
          @cidr_table
        )

      {:error, _} ->
        false
    end
  end

  defp ip_in_cidr?(ip_tuple, cidr_string) do
    case String.split(cidr_string, "/") do
      [network_str, mask_str] ->
        case {:inet.parse_address(String.to_charlist(network_str)), Integer.parse(mask_str)} do
          {{:ok, network_tuple}, {mask, ""}} ->
            check_ip_in_network(ip_tuple, network_tuple, mask)
          _ ->
            false
        end
      _ ->
        false
    end
  end

  defp check_ip_in_network(ip, network, mask) when tuple_size(ip) == 4 and tuple_size(network) == 4 do
    # IPv4
    ip_int = ip_to_integer(ip)
    network_int = ip_to_integer(network)
    mask_bits = bsl(0xFFFFFFFF, 32 - mask) &&& 0xFFFFFFFF

    (ip_int &&& mask_bits) == (network_int &&& mask_bits)
  end

  defp check_ip_in_network(ip, network, mask) when tuple_size(ip) == 8 and tuple_size(network) == 8 do
    # IPv6
    ip_int = ipv6_to_integer(ip)
    network_int = ipv6_to_integer(network)
    mask_bits = bsl(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 128 - mask)

    (ip_int &&& mask_bits) == (network_int &&& mask_bits)
  end

  defp check_ip_in_network(_, _, _), do: false

  defp ip_to_integer({a, b, c, d}) do
    bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
  end

  defp ipv6_to_integer({a, b, c, d, e, f, g, h}) do
    bsl(a, 112) + bsl(b, 96) + bsl(c, 80) + bsl(d, 64) +
    bsl(e, 48) + bsl(f, 32) + bsl(g, 16) + h
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip) when is_binary(ip), do: ip
end
