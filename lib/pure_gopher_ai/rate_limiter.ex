defmodule PureGopherAi.RateLimiter do
  @moduledoc """
  Rate limiter using ETS for tracking requests per IP.
  Uses a sliding window algorithm for accurate rate limiting.

  Configurable via:
  - :rate_limit_requests - max requests per window (default: 60)
  - :rate_limit_window_ms - window size in milliseconds (default: 60000 = 1 minute)
  - :rate_limit_enabled - enable/disable (default: true)
  """

  use GenServer
  require Logger

  @table_name :rate_limiter
  @bans_table :rate_limiter_bans
  @cleanup_interval 60_000  # Clean up old entries every minute

  # Client API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request from the given IP is allowed.
  Returns {:ok, remaining} if allowed, {:error, :rate_limited, retry_after_ms} if not.
  """
  def check(ip) when is_tuple(ip) do
    check(format_ip(ip))
  end

  def check(ip) when is_binary(ip) do
    if banned?(ip) do
      {:error, :banned}
    else
      if enabled?() do
        GenServer.call(__MODULE__, {:check, ip})
      else
        {:ok, :unlimited}
      end
    end
  end

  @doc """
  Returns the current request count for an IP.
  """
  def get_count(ip) when is_tuple(ip) do
    get_count(format_ip(ip))
  end

  def get_count(ip) when is_binary(ip) do
    case :ets.lookup(@table_name, ip) do
      [{^ip, timestamps}] -> length(timestamps)
      [] -> 0
    end
  end

  @doc """
  Resets the rate limit for an IP.
  """
  def reset(ip) when is_tuple(ip) do
    reset(format_ip(ip))
  end

  def reset(ip) when is_binary(ip) do
    :ets.delete(@table_name, ip)
    :ok
  end

  @doc """
  Checks if rate limiting is enabled.
  """
  def enabled? do
    Application.get_env(:pure_gopher_ai, :rate_limit_enabled, true)
  end

  @doc """
  Gets the configured rate limit.
  """
  def limit do
    Application.get_env(:pure_gopher_ai, :rate_limit_requests, 60)
  end

  @doc """
  Gets the configured window size in milliseconds.
  """
  def window_ms do
    Application.get_env(:pure_gopher_ai, :rate_limit_window_ms, 60_000)
  end

  @doc """
  Gets rate limiter statistics.
  """
  def stats do
    tracked_ips = :ets.info(@table_name, :size) || 0
    banned_ips = :ets.info(@bans_table, :size) || 0

    %{
      enabled: enabled?(),
      limit: limit(),
      window_ms: window_ms(),
      tracked_ips: tracked_ips,
      banned_ips: banned_ips
    }
  end

  @doc """
  Bans an IP address.
  """
  def ban(ip) when is_tuple(ip) do
    ban(format_ip(ip))
  end

  def ban(ip) when is_binary(ip) do
    :ets.insert(@bans_table, {ip, System.monotonic_time(:second)})
    Logger.warning("Banned IP: #{ip}")
    :ok
  end

  @doc """
  Unbans an IP address.
  """
  def unban(ip) when is_tuple(ip) do
    unban(format_ip(ip))
  end

  def unban(ip) when is_binary(ip) do
    :ets.delete(@bans_table, ip)
    Logger.info("Unbanned IP: #{ip}")
    :ok
  end

  @doc """
  Checks if an IP is banned.
  """
  def banned?(ip) when is_tuple(ip) do
    banned?(format_ip(ip))
  end

  def banned?(ip) when is_binary(ip) do
    case :ets.lookup(@bans_table, ip) do
      [{^ip, _}] -> true
      [] -> false
    end
  end

  @doc """
  Lists all banned IPs.
  """
  def list_bans do
    :ets.tab2list(@bans_table)
    |> Enum.map(fn {ip, timestamp} -> {ip, timestamp} end)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for storing rate limit data
    :ets.new(@table_name, [:named_table, :public, :set])
    # Create ETS table for bans
    :ets.new(@bans_table, [:named_table, :public, :set])

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("RateLimiter started: #{limit()} requests per #{div(window_ms(), 1000)}s")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check, ip}, _from, state) do
    now = System.monotonic_time(:millisecond)
    window = window_ms()
    max_requests = limit()
    cutoff = now - window

    # Get existing timestamps, filter out old ones
    timestamps =
      case :ets.lookup(@table_name, ip) do
        [{^ip, ts}] -> Enum.filter(ts, &(&1 > cutoff))
        [] -> []
      end

    current_count = length(timestamps)

    if current_count < max_requests do
      # Allow request, add timestamp
      new_timestamps = [now | timestamps]
      :ets.insert(@table_name, {ip, new_timestamps})
      remaining = max_requests - current_count - 1
      {:reply, {:ok, remaining}, state}
    else
      # Rate limited - calculate retry after
      oldest = Enum.min(timestamps)
      retry_after = oldest + window - now
      {:reply, {:error, :rate_limited, retry_after}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_old_entries do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms()

    # Iterate through all entries and clean up old timestamps
    :ets.foldl(
      fn {ip, timestamps}, acc ->
        filtered = Enum.filter(timestamps, &(&1 > cutoff))

        if filtered == [] do
          :ets.delete(@table_name, ip)
        else
          :ets.insert(@table_name, {ip, filtered})
        end

        acc
      end,
      :ok,
      @table_name
    )
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip) when is_binary(ip), do: ip
end
