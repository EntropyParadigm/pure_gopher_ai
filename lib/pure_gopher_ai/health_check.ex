defmodule PureGopherAi.HealthCheck do
  @moduledoc """
  Health check and status API for monitoring and container orchestration.

  Provides:
  - Liveness probes (is the app alive?)
  - Readiness probes (is the app ready to serve traffic?)
  - Detailed health status with component checks
  - System metrics (memory, processes, uptime)

  Compatible with Kubernetes and Docker health checks.
  """

  alias PureGopherAi.Telemetry
  alias PureGopherAi.ResponseCache
  alias PureGopherAi.Rag
  alias PureGopherAi.Config

  @doc """
  Simple liveness check.
  Returns :ok if the application is alive and responding.
  """
  def live do
    :ok
  end

  @doc """
  Readiness check.
  Returns :ok if all critical components are ready to serve traffic.
  Returns {:error, reasons} if any component is not ready.
  """
  def ready do
    checks = [
      check_ai_serving(),
      check_rate_limiter(),
      check_conversation_store(),
      check_response_cache()
    ]

    failed = Enum.filter(checks, fn {status, _} -> status == :error end)

    if failed == [] do
      :ok
    else
      {:error, Enum.map(failed, fn {_, reason} -> reason end)}
    end
  end

  @doc """
  Full health status with all component checks and metrics.
  Returns a map with detailed health information.
  """
  def status do
    %{
      status: determine_overall_status(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: version_info(),
      uptime: uptime_info(),
      system: system_metrics(),
      components: component_status(),
      telemetry: telemetry_summary()
    }
  end

  @doc """
  Returns health status as JSON string.
  """
  def status_json do
    Jason.encode!(status(), pretty: true)
  end

  @doc """
  Returns a simple text status for Gopher clients.
  """
  def status_text do
    health = status()

    """
    PureGopherAI Health Status
    ==========================

    Overall Status: #{String.upcase(to_string(health.status))}
    Timestamp: #{health.timestamp}

    Version Info:
      App: #{health.version.app}
      Elixir: #{health.version.elixir}
      OTP: #{health.version.otp}

    Uptime:
      Started: #{health.uptime.started_at || "Unknown"}
      Duration: #{health.uptime.formatted}

    System Metrics:
      Memory (Total): #{format_bytes(health.system.memory.total)}
      Memory (Processes): #{format_bytes(health.system.memory.processes)}
      Memory (Atoms): #{format_bytes(health.system.memory.atom)}
      Memory (Binary): #{format_bytes(health.system.memory.binary)}
      Processes: #{health.system.processes.count} / #{health.system.processes.limit}
      Ports: #{health.system.ports.count} / #{health.system.ports.limit}
      Schedulers: #{health.system.schedulers}

    Components:
    #{format_components(health.components)}

    Telemetry:
      Total Requests: #{health.telemetry.total_requests}
      Requests/Hour: #{health.telemetry.requests_per_hour}
      Error Rate: #{health.telemetry.error_rate}%
      Avg Latency: #{health.telemetry.avg_latency_ms}ms
    """
  end

  # Private functions

  defp determine_overall_status do
    case ready() do
      :ok -> :healthy
      {:error, _} -> :degraded
    end
  end

  defp version_info do
    %{
      app: "1.0.0",
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release))
    }
  end

  defp uptime_info do
    start_time = Config.start_time()

    if start_time do
      now = System.system_time(:second)
      uptime_seconds = now - start_time

      %{
        started_at: DateTime.from_unix!(start_time) |> DateTime.to_iso8601(),
        uptime_seconds: uptime_seconds,
        formatted: format_duration(uptime_seconds)
      }
    else
      %{
        started_at: nil,
        uptime_seconds: 0,
        formatted: "Unknown"
      }
    end
  end

  defp system_metrics do
    memory = :erlang.memory()

    %{
      memory: %{
        total: memory[:total],
        processes: memory[:processes],
        atom: memory[:atom],
        binary: memory[:binary],
        ets: memory[:ets]
      },
      processes: %{
        count: :erlang.system_info(:process_count),
        limit: :erlang.system_info(:process_limit)
      },
      ports: %{
        count: :erlang.system_info(:port_count),
        limit: :erlang.system_info(:port_limit)
      },
      schedulers: :erlang.system_info(:schedulers_online),
      node: Node.self()
    }
  end

  defp component_status do
    %{
      ai_serving: check_component(:ai_serving),
      rate_limiter: check_component(:rate_limiter),
      conversation_store: check_component(:conversation_store),
      response_cache: check_component(:response_cache),
      rag: check_component(:rag),
      telemetry: check_component(:telemetry),
      guestbook: check_component(:guestbook),
      bulletin_board: check_component(:bulletin_board)
    }
  end

  defp check_component(component) do
    {status, _reason} = case component do
      :ai_serving -> check_ai_serving()
      :rate_limiter -> check_rate_limiter()
      :conversation_store -> check_conversation_store()
      :response_cache -> check_response_cache()
      :rag -> check_rag()
      :telemetry -> check_telemetry()
      :guestbook -> check_guestbook()
      :bulletin_board -> check_bulletin_board()
    end

    %{
      status: if(status == :ok, do: :healthy, else: :unhealthy)
    }
  end

  defp check_ai_serving do
    if Process.whereis(PureGopherAi.Serving) do
      {:ok, "AI Serving is running"}
    else
      {:error, "AI Serving is not running"}
    end
  end

  defp check_rate_limiter do
    if Process.whereis(PureGopherAi.RateLimiter) do
      {:ok, "Rate Limiter is running"}
    else
      {:error, "Rate Limiter is not running"}
    end
  end

  defp check_conversation_store do
    if Process.whereis(PureGopherAi.ConversationStore) do
      {:ok, "Conversation Store is running"}
    else
      {:error, "Conversation Store is not running"}
    end
  end

  defp check_response_cache do
    if Process.whereis(PureGopherAi.ResponseCache) do
      try do
        _stats = ResponseCache.stats()
        {:ok, "Response Cache is running"}
      rescue
        _ -> {:error, "Response Cache is not responding"}
      end
    else
      {:error, "Response Cache is not running"}
    end
  end

  defp check_rag do
    try do
      _stats = Rag.stats()
      {:ok, "RAG is running"}
    rescue
      _ -> {:error, "RAG is not available"}
    end
  end

  defp check_telemetry do
    if Process.whereis(PureGopherAi.Telemetry) do
      {:ok, "Telemetry is running"}
    else
      {:error, "Telemetry is not running"}
    end
  end

  defp check_guestbook do
    if Process.whereis(PureGopherAi.Guestbook) do
      {:ok, "Guestbook is running"}
    else
      {:error, "Guestbook is not running"}
    end
  end

  defp check_bulletin_board do
    if Process.whereis(PureGopherAi.BulletinBoard) do
      {:ok, "Bulletin Board is running"}
    else
      {:error, "Bulletin Board is not running"}
    end
  end

  defp telemetry_summary do
    try do
      stats = Telemetry.format_stats()
      %{
        total_requests: stats.total_requests,
        requests_per_hour: stats.requests_per_hour,
        error_rate: stats.error_rate,
        avg_latency_ms: stats.avg_latency_ms
      }
    rescue
      _ -> %{
        total_requests: 0,
        requests_per_hour: 0,
        error_rate: 0.0,
        avg_latency_ms: 0
      }
    end
  end

  defp format_duration(seconds) when seconds < 60 do
    "#{seconds}s"
  end

  defp format_duration(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration(seconds) when seconds < 86400 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp format_duration(seconds) do
    days = div(seconds, 86400)
    hours = div(rem(seconds, 86400), 3600)
    "#{days}d #{hours}h"
  end

  defp format_bytes(bytes) when bytes < 1024 do
    "#{bytes} B"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    kb = Float.round(bytes / 1024, 1)
    "#{kb} KB"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 do
    mb = Float.round(bytes / (1024 * 1024), 1)
    "#{mb} MB"
  end

  defp format_bytes(bytes) do
    gb = Float.round(bytes / (1024 * 1024 * 1024), 2)
    "#{gb} GB"
  end

  defp format_components(components) do
    components
    |> Enum.map(fn {name, %{status: status}} ->
      status_str = if status == :healthy, do: "OK", else: "FAIL"
      "  #{name}: #{status_str}"
    end)
    |> Enum.join("\n")
  end
end
