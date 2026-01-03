defmodule PureGopherAi.Debug do
  @moduledoc """
  Debug logging utilities with configurable verbosity.

  All debug logging can be toggled via configuration:

      config :pure_gopher_ai,
        debug_enabled: true,           # Master switch for all debug logging
        debug_log_requests: true,      # Log incoming requests
        debug_log_ai_prompts: true,    # Log AI prompts and responses
        debug_log_timing: true         # Log timing information

  Or via environment variable:

      DEBUG_ENABLED=true mix run --no-halt

  Usage:

      alias PureGopherAi.Debug

      Debug.log(:request, "Incoming request: \#{selector}")
      Debug.log(:ai, "Prompt: \#{prompt}")
      Debug.log(:timing, "Generated in \#{elapsed}ms")
  """

  require Logger

  @doc """
  Returns true if debug mode is enabled.
  """
  def enabled? do
    Application.get_env(:pure_gopher_ai, :debug_enabled, false)
  end

  @doc """
  Returns true if a specific debug category is enabled.
  Categories: :request, :ai, :timing
  """
  def enabled?(category) do
    enabled?() && category_enabled?(category)
  end

  defp category_enabled?(:request) do
    Application.get_env(:pure_gopher_ai, :debug_log_requests, true)
  end

  defp category_enabled?(:ai) do
    Application.get_env(:pure_gopher_ai, :debug_log_ai_prompts, true)
  end

  defp category_enabled?(:timing) do
    Application.get_env(:pure_gopher_ai, :debug_log_timing, true)
  end

  defp category_enabled?(_), do: true

  @doc """
  Logs a debug message if debug mode is enabled.

  ## Examples

      Debug.log("Simple message")
      Debug.log(:request, "Request from \#{ip}")
      Debug.log(:ai, "Prompt: \#{prompt}")
      Debug.log(:timing, "Operation took \#{ms}ms")
  """
  def log(message) when is_binary(message) do
    if enabled?() do
      Logger.debug("[DEBUG] #{message}")
    end
  end

  def log(category, message) when is_atom(category) and is_binary(message) do
    if enabled?(category) do
      prefix = category_prefix(category)
      Logger.debug("[DEBUG:#{prefix}] #{message}")
    end
  end

  defp category_prefix(:request), do: "REQ"
  defp category_prefix(:ai), do: "AI"
  defp category_prefix(:timing), do: "TIME"
  defp category_prefix(other), do: String.upcase(to_string(other))

  @doc """
  Logs timing information for a block of code.
  Only executes timing logic if debug mode is enabled.

  ## Examples

      result = Debug.timed("AI generation", fn ->
        AiEngine.generate(prompt)
      end)
  """
  def timed(label, fun) when is_function(fun, 0) do
    if enabled?(:timing) do
      start = System.monotonic_time(:millisecond)
      result = fun.()
      elapsed = System.monotonic_time(:millisecond) - start
      log(:timing, "#{label}: #{elapsed}ms")
      result
    else
      fun.()
    end
  end

  @doc """
  Logs AI-related debug info (prompts, responses).
  Truncates long content for readability.
  """
  def log_ai(label, content, opts \\ []) do
    if enabled?(:ai) do
      max_length = Keyword.get(opts, :max_length, 200)
      truncated = truncate(content, max_length)
      log(:ai, "#{label}: #{truncated}")
    end
  end

  @doc """
  Logs request debug info.
  """
  def log_request(selector, client_ip, opts \\ []) do
    if enabled?(:request) do
      network = Keyword.get(opts, :network, :unknown)
      log(:request, "[#{network}] #{client_ip} -> #{selector}")
    end
  end

  defp truncate(content, max_length) when is_binary(content) do
    if String.length(content) > max_length do
      String.slice(content, 0, max_length) <> "..."
    else
      content
    end
  end

  defp truncate(content, _), do: inspect(content)
end
