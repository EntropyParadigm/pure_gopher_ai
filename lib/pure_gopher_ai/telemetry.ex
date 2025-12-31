defmodule PureGopherAi.Telemetry do
  @moduledoc """
  Telemetry and metrics collection for the Gopher server.
  Tracks requests, latency, errors, and per-model/network stats.

  Metrics are stored in ETS for fast access and exposed via /stats selector.
  """

  use GenServer
  require Logger

  @table_name :telemetry_metrics
  @reset_interval 86_400_000  # Reset daily stats every 24 hours

  # Client API

  @doc """
  Starts the telemetry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a request.
  """
  def record_request(selector, opts \\ []) do
    network = Keyword.get(opts, :network, :clearnet)
    model = Keyword.get(opts, :model)
    persona = Keyword.get(opts, :persona)

    increment(:total_requests)
    increment(:"requests_#{network}")

    # Track by selector type
    selector_type = categorize_selector(selector)
    increment(:"requests_#{selector_type}")

    if model do
      increment(:"requests_model_#{model}")
    end

    if persona do
      increment(:"requests_persona_#{persona}")
    end
  end

  @doc """
  Records request latency.
  """
  def record_latency(latency_ms, opts \\ []) do
    model = Keyword.get(opts, :model)

    # Update average latency
    update_average(:avg_latency_ms, latency_ms)

    if model do
      update_average(:"avg_latency_#{model}", latency_ms)
    end

    # Track max latency
    update_max(:max_latency_ms, latency_ms)
  end

  @doc """
  Records an error.
  """
  def record_error(error_type \\ :general) do
    increment(:total_errors)
    increment(:"errors_#{error_type}")
  end

  @doc """
  Records a cache event.
  """
  def record_cache_event(event_type) when event_type in [:hit, :miss, :write] do
    increment(:"cache_#{event_type}")
  end

  @doc """
  Gets all metrics as a map.
  """
  def get_metrics do
    :ets.tab2list(@table_name)
    |> Enum.into(%{})
  end

  @doc """
  Gets a specific metric value.
  """
  def get_metric(name) do
    case :ets.lookup(@table_name, name) do
      [{^name, value}] -> value
      [] -> 0
    end
  end

  @doc """
  Gets formatted stats for display.
  """
  def format_stats do
    metrics = get_metrics()

    total_requests = Map.get(metrics, :total_requests, 0)
    clearnet_requests = Map.get(metrics, :requests_clearnet, 0)
    tor_requests = Map.get(metrics, :requests_tor, 0)
    total_errors = Map.get(metrics, :total_errors, 0)

    ask_requests = Map.get(metrics, :requests_ask, 0)
    chat_requests = Map.get(metrics, :requests_chat, 0)
    static_requests = Map.get(metrics, :requests_static, 0)

    avg_latency = Map.get(metrics, :avg_latency_ms, 0)
    max_latency = Map.get(metrics, :max_latency_ms, 0)

    error_rate =
      if total_requests > 0 do
        Float.round(total_errors / total_requests * 100, 2)
      else
        0.0
      end

    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)
    uptime_hours = Float.round(uptime_ms / 3_600_000, 1)

    requests_per_hour =
      if uptime_hours > 0 do
        Float.round(total_requests / uptime_hours, 1)
      else
        0.0
      end

    %{
      total_requests: total_requests,
      clearnet_requests: clearnet_requests,
      tor_requests: tor_requests,
      ask_requests: ask_requests,
      chat_requests: chat_requests,
      static_requests: static_requests,
      total_errors: total_errors,
      error_rate: error_rate,
      avg_latency_ms: round(avg_latency),
      max_latency_ms: max_latency,
      uptime_hours: uptime_hours,
      requests_per_hour: requests_per_hour
    }
  end

  @doc """
  Resets all metrics.
  """
  def reset do
    :ets.delete_all_objects(@table_name)
    init_counters()
    :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set])
    init_counters()
    schedule_reset()
    Logger.info("Telemetry started")
    {:ok, %{start_time: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:daily_reset, state) do
    Logger.info("Telemetry: daily stats reset")
    reset()
    schedule_reset()
    {:noreply, state}
  end

  # Private functions

  defp init_counters do
    counters = [
      :total_requests,
      :requests_clearnet,
      :requests_tor,
      :requests_ask,
      :requests_chat,
      :requests_static,
      :requests_other,
      :total_errors,
      :avg_latency_ms,
      :max_latency_ms,
      :latency_count
    ]

    Enum.each(counters, fn counter ->
      :ets.insert(@table_name, {counter, 0})
    end)
  end

  defp increment(counter) do
    :ets.update_counter(@table_name, counter, 1, {counter, 0})
  rescue
    _ ->
      :ets.insert(@table_name, {counter, 1})
  end

  defp update_average(avg_key, value) do
    count_key = :"#{avg_key}_count"

    # Get current values
    current_avg = get_metric(avg_key)
    current_count = get_metric(count_key)

    # Calculate new average
    new_count = current_count + 1
    new_avg = (current_avg * current_count + value) / new_count

    :ets.insert(@table_name, {avg_key, new_avg})
    :ets.insert(@table_name, {count_key, new_count})
  end

  defp update_max(key, value) do
    current_max = get_metric(key)

    if value > current_max do
      :ets.insert(@table_name, {key, value})
    end
  end

  defp categorize_selector(selector) do
    cond do
      String.starts_with?(selector, "/ask") or String.starts_with?(selector, "/persona-") ->
        :ask

      String.starts_with?(selector, "/chat") ->
        :chat

      String.starts_with?(selector, "/files") or selector in ["", "/"] ->
        :static

      true ->
        :other
    end
  end

  defp schedule_reset do
    Process.send_after(self(), :daily_reset, @reset_interval)
  end
end
