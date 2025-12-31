defmodule PureGopherAi.GopherHandler do
  @moduledoc """
  Gopher protocol handler implementing RFC 1436.
  Uses ThousandIsland for TCP connection handling.
  Supports both clearnet and Tor hidden service connections.
  Serves static content via gophermap.
  """

  use ThousandIsland.Handler
  require Logger

  alias PureGopherAi.Gophermap

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    # Extract network type from handler options
    network = Keyword.get(state, :network, :clearnet)
    {:continue, Map.put(%{}, :network, network)}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    network = Map.get(state, :network, :clearnet)
    {host, port} = get_host_port(network)

    # Gopher selectors are CRLF terminated
    selector =
      data
      |> String.trim()
      |> String.trim_trailing("\r\n")

    network_label = if network == :tor, do: "[Tor]", else: "[Clearnet]"
    Logger.info("#{network_label} Gopher request: #{inspect(selector)}")

    response = route_selector(selector, host, port, network)
    ThousandIsland.Socket.send(socket, response)

    {:close, state}
  end

  # Get appropriate host/port based on network type
  defp get_host_port(:tor) do
    onion = Application.get_env(:pure_gopher_ai, :onion_address)

    if onion do
      {onion, 70}
    else
      {"[onion-address]", 70}
    end
  end

  defp get_host_port(:clearnet) do
    host = Application.get_env(:pure_gopher_ai, :clearnet_host, "localhost")
    port = Application.get_env(:pure_gopher_ai, :clearnet_port, 7070)
    {host, port}
  end

  # Route selector to appropriate handler
  defp route_selector("", host, port, network), do: root_menu(host, port, network)
  defp route_selector("/", host, port, network), do: root_menu(host, port, network)

  # AI queries
  defp route_selector("/ask\t" <> query, host, port, _network),
    do: handle_ask(query, host, port)

  defp route_selector("/ask " <> query, host, port, _network),
    do: handle_ask(query, host, port)

  defp route_selector("/ask", host, port, _network),
    do: ask_prompt(host, port)

  # Server info
  defp route_selector("/about", host, port, network),
    do: about_page(host, port, network)

  # Static content via gophermap
  defp route_selector("/files" <> rest, host, port, _network),
    do: serve_static(rest, host, port)

  # Catch-all: check gophermap content, then error
  defp route_selector(selector, host, port, _network) do
    # Try to serve from gophermap content directory
    if Gophermap.exists?(selector) do
      case Gophermap.serve(selector, host, port) do
        {:ok, content} -> content
        {:error, _} -> error_response("Failed to serve: #{selector}")
      end
    else
      error_response("Unknown selector: #{selector}")
    end
  end

  # Root menu - Gopher type 1 (directory)
  defp root_menu(host, port, network) do
    network_banner =
      case network do
        :tor -> "Tor Hidden Service"
        :clearnet -> "Clearnet"
      end

    content_dir = Gophermap.content_dir()
    has_files = File.exists?(content_dir) and File.dir?(content_dir)

    files_section =
      if has_files do
        "1Browse Files\t/files\t#{host}\t#{port}\r\n"
      else
        ""
      end

    """
    iWelcome to PureGopherAI Server\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPowered by Elixir + Bumblebee + Metal GPU\t\t#{host}\t#{port}
    iNetwork: #{network_banner}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i=== AI Services ===\t\t#{host}\t#{port}
    7Ask AI a question\t/ask\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i=== Server ===\t\t#{host}\t#{port}
    #{files_section}0About this server\t/about\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iType your question after selecting 'Ask AI'\t\t#{host}\t#{port}
    .
    """
  end

  # Prompt for AI query (Type 7 search)
  defp ask_prompt(host, port) do
    """
    iAsk AI a Question\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter your question below:\t\t#{host}\t#{port}
    .
    """
  end

  # Handle AI query
  defp handle_ask(query, host, port) when byte_size(query) > 0 do
    Logger.info("AI Query: #{query}")

    start_time = System.monotonic_time(:millisecond)
    response = PureGopherAi.AiEngine.generate(query)
    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.info("AI Response generated in #{elapsed}ms")

    format_text_response(
      """
      Query: #{query}

      Response:
      #{response}

      ---
      Generated in #{elapsed}ms using GPU acceleration
      """,
      host,
      port
    )
  end

  defp handle_ask(_, _host, _port), do: error_response("Please provide a query after /ask")

  # Serve static files via gophermap
  defp serve_static(path, host, port) do
    # Normalize path
    normalized = if path == "" or path == "/", do: "", else: path

    case Gophermap.serve(normalized, host, port) do
      {:ok, content} ->
        content

      {:error, :not_found} ->
        error_response("File not found: #{path}")

      {:error, reason} ->
        error_response("Error serving file: #{inspect(reason)}")
    end
  end

  # About page - server stats
  defp about_page(host, port, network) do
    {:ok, hostname} = :inet.gethostname()
    memory = :erlang.memory()
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)
    uptime_min = div(uptime_ms, 60_000)

    backend_info =
      case :os.type() do
        {:unix, :darwin} -> "Torchx (Metal MPS GPU)"
        _ -> "EXLA (CPU)"
      end

    network_info =
      case network do
        :tor -> "Tor Hidden Service (port 70)"
        :clearnet -> "Clearnet (port #{port})"
      end

    content_dir = Gophermap.content_dir()
    content_status = if File.exists?(content_dir), do: "Active", else: "Not configured"

    format_text_response(
      """
      === PureGopherAI Server Stats ===

      Host: #{hostname}
      Network: #{network_info}
      Protocol: Gopher (RFC 1436)

      Runtime: Elixir #{System.version()} / OTP #{System.otp_release()}
      Uptime: #{uptime_min} minutes
      Memory (Total): #{div(memory[:total], 1_048_576)} MB
      Memory (Processes): #{div(memory[:processes], 1_048_576)} MB

      AI Backend: Bumblebee
      Compute Backend: #{backend_info}
      Model: GPT-2 (openai-community/gpt2)

      Content Directory: #{content_dir}
      Content Status: #{content_status}

      TCP Server: ThousandIsland
      Architecture: OTP Supervision Tree
      """,
      host,
      port
    )
  end

  # Format as Gopher text response (type 0)
  defp format_text_response(text, host, port) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&"i#{&1}\t\t#{host}\t#{port}")
      |> Enum.join("\r\n")

    lines <> "\r\n.\r\n"
  end

  # Error response
  defp error_response(message) do
    """
    3#{message}\t\terror.host\t1
    .
    """
  end
end
