defmodule PureGopherAi.Config do
  @moduledoc """
  Configuration module using persistent terms for fast, read-heavy access.

  Persistent terms are optimized for configurations that are:
  - Read frequently (every request)
  - Rarely changed (typically only at startup)

  This provides ~10x faster access compared to Application.get_env/3.
  """

  @persistent_term_key :pure_gopher_ai_config

  @doc """
  Initialize persistent terms with application configuration.
  Should be called once at application startup.
  """
  def init do
    config = %{
      # Server endpoints
      clearnet_host: Application.get_env(:pure_gopher_ai, :clearnet_host, "localhost"),
      clearnet_port: Application.get_env(:pure_gopher_ai, :clearnet_port, 7070),
      onion_address: Application.get_env(:pure_gopher_ai, :onion_address),
      tor_enabled: Application.get_env(:pure_gopher_ai, :tor_enabled, false),
      tor_port: Application.get_env(:pure_gopher_ai, :tor_port, 7071),
      gemini_enabled: Application.get_env(:pure_gopher_ai, :gemini_enabled, false),
      gemini_port: Application.get_env(:pure_gopher_ai, :gemini_port, 1965),
      finger_enabled: Application.get_env(:pure_gopher_ai, :finger_enabled, false),
      finger_port: Application.get_env(:pure_gopher_ai, :finger_port, 79),
      hostname: Application.get_env(:pure_gopher_ai, :hostname, "localhost"),

      # AI settings
      streaming_enabled: Application.get_env(:pure_gopher_ai, :streaming_enabled, true),

      # Content directories
      content_dir: expand_path(Application.get_env(:pure_gopher_ai, :content_dir, "~/.gopher")),
      rag_docs_dir: expand_path(Application.get_env(:pure_gopher_ai, :rag_docs_dir, "~/.gopher/docs")),
      rag_enabled: Application.get_env(:pure_gopher_ai, :rag_enabled, true),
      rag_chunk_size: Application.get_env(:pure_gopher_ai, :rag_chunk_size, 512),
      rag_chunk_overlap: Application.get_env(:pure_gopher_ai, :rag_chunk_overlap, 50),

      # Admin
      admin_token: Application.get_env(:pure_gopher_ai, :admin_token),

      # Blocklist
      blocklist_enabled: Application.get_env(:pure_gopher_ai, :blocklist_enabled, false),

      # Startup time for uptime calculation
      start_time: System.system_time(:second)
    }

    :persistent_term.put(@persistent_term_key, config)
    :ok
  end

  @doc """
  Get a configuration value. Falls back to default if not found.
  """
  def get(key, default \\ nil) do
    config = :persistent_term.get(@persistent_term_key, %{})
    Map.get(config, key, default)
  end

  @doc """
  Get the entire configuration map.
  """
  def all do
    :persistent_term.get(@persistent_term_key, %{})
  end

  # Fast accessor functions for commonly used values

  @doc "Get clearnet host"
  def clearnet_host, do: get(:clearnet_host)

  @doc "Get clearnet port"
  def clearnet_port, do: get(:clearnet_port)

  @doc "Get onion address"
  def onion_address, do: get(:onion_address)

  @doc "Check if Tor is enabled"
  def tor_enabled?, do: get(:tor_enabled)

  @doc "Get Tor port"
  def tor_port, do: get(:tor_port)

  @doc "Check if Gemini is enabled"
  def gemini_enabled?, do: get(:gemini_enabled)

  @doc "Get Gemini port"
  def gemini_port, do: get(:gemini_port)

  @doc "Check if Finger is enabled"
  def finger_enabled?, do: get(:finger_enabled)

  @doc "Get Finger port"
  def finger_port, do: get(:finger_port)

  @doc "Get hostname"
  def hostname, do: get(:hostname)

  @doc "Check if streaming is enabled"
  def streaming_enabled?, do: get(:streaming_enabled)

  @doc "Get content directory"
  def content_dir, do: get(:content_dir)

  @doc "Get RAG docs directory"
  def rag_docs_dir, do: get(:rag_docs_dir)

  @doc "Check if RAG is enabled"
  def rag_enabled?, do: get(:rag_enabled)

  @doc "Get RAG chunk size"
  def rag_chunk_size, do: get(:rag_chunk_size)

  @doc "Get RAG chunk overlap"
  def rag_chunk_overlap, do: get(:rag_chunk_overlap)

  @doc "Get admin token"
  def admin_token, do: get(:admin_token)

  @doc "Check if blocklist is enabled"
  def blocklist_enabled?, do: get(:blocklist_enabled)

  @doc "Get application start time (for uptime calculation)"
  def start_time, do: get(:start_time)

  @doc "Get host/port tuple for a network type"
  def host_port(:tor) do
    case onion_address() do
      nil -> {"[onion-address]", 70}
      onion -> {onion, 70}
    end
  end

  def host_port(:clearnet) do
    {clearnet_host(), clearnet_port()}
  end

  # Private helpers

  defp expand_path(path) when is_binary(path) do
    Path.expand(path)
  end

  defp expand_path(nil), do: nil
end
