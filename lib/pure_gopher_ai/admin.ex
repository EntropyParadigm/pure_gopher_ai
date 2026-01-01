defmodule PureGopherAi.Admin do
  @moduledoc """
  Admin interface for the Gopher server.
  Provides stats, cache management, and configuration via token-based auth.
  """

  require Logger

  alias PureGopherAi.RateLimiter
  alias PureGopherAi.ResponseCache
  alias PureGopherAi.Telemetry
  alias PureGopherAi.ConversationStore

  @doc """
  Gets the admin token from config or environment.
  Returns nil if admin is disabled.
  """
  def get_token do
    System.get_env("ADMIN_TOKEN") ||
      Application.get_env(:pure_gopher_ai, :admin_token)
  end

  @doc """
  Checks if admin is enabled (has a token configured).
  """
  def enabled? do
    get_token() != nil
  end

  @doc """
  Validates an admin token.
  """
  def valid_token?(token) do
    case get_token() do
      nil -> false
      configured_token -> secure_compare(token, configured_token)
    end
  end

  # Constant-time string comparison to prevent timing attacks
  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_compare(_, _), do: false

  @doc """
  Gets detailed system stats for admin view.
  """
  def system_stats do
    memory = :erlang.memory()
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)

    %{
      memory: %{
        total_mb: div(memory[:total], 1_048_576),
        processes_mb: div(memory[:processes], 1_048_576),
        binary_mb: div(memory[:binary], 1_048_576),
        ets_mb: div(memory[:ets], 1_048_576),
        atom_mb: div(memory[:atom], 1_048_576)
      },
      processes: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online),
      uptime_hours: Float.round(uptime_ms / 3_600_000, 2),
      otp_version: :erlang.system_info(:otp_release) |> List.to_string(),
      elixir_version: System.version()
    }
  end

  @doc """
  Gets rate limiter stats.
  """
  def rate_limiter_stats do
    RateLimiter.stats()
  end

  @doc """
  Gets cache stats.
  """
  def cache_stats do
    ResponseCache.stats()
  end

  @doc """
  Clears the response cache.
  """
  def clear_cache do
    ResponseCache.clear()
    Logger.info("Admin: Cache cleared")
    :ok
  end

  @doc """
  Clears all conversation sessions.
  """
  def clear_sessions do
    ConversationStore.clear_all()
    Logger.info("Admin: All sessions cleared")
    :ok
  end

  @doc """
  Resets telemetry metrics.
  """
  def reset_metrics do
    Telemetry.reset()
    Logger.info("Admin: Metrics reset")
    :ok
  end

  @doc """
  Gets list of banned IPs.
  """
  def list_bans do
    RateLimiter.list_bans()
  end

  @doc """
  Bans an IP address.
  """
  def ban_ip(ip_string) do
    case parse_ip(ip_string) do
      {:ok, ip} ->
        RateLimiter.ban(ip)
        Logger.info("Admin: Banned IP #{ip_string}")
        :ok
      {:error, _} ->
        {:error, :invalid_ip}
    end
  end

  @doc """
  Unbans an IP address.
  """
  def unban_ip(ip_string) do
    case parse_ip(ip_string) do
      {:ok, ip} ->
        RateLimiter.unban(ip)
        Logger.info("Admin: Unbanned IP #{ip_string}")
        :ok
      {:error, _} ->
        {:error, :invalid_ip}
    end
  end

  @doc """
  Generates a random admin token.
  """
  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # Parse IP string to tuple
  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, :invalid_ip}
    end
  end
end
