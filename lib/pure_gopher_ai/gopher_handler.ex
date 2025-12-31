defmodule PureGopherAi.GopherHandler do
  @moduledoc """
  Gopher protocol handler implementing RFC 1436.
  Uses ThousandIsland for TCP connection handling.
  """

  use ThousandIsland.Handler
  require Logger

  @server_host "localhost"
  @server_port 7070

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    # Gopher selectors are CRLF terminated
    selector =
      data
      |> String.trim()
      |> String.trim_trailing("\r\n")

    Logger.info("Gopher request: #{inspect(selector)}")

    response = route_selector(selector)
    ThousandIsland.Socket.send(socket, response)

    {:close, state}
  end

  # Route selector to appropriate handler
  defp route_selector(""), do: root_menu()
  defp route_selector("/"), do: root_menu()
  defp route_selector("/ask\t" <> query), do: handle_ask(query)
  defp route_selector("/ask " <> query), do: handle_ask(query)
  defp route_selector("/about"), do: about_page()
  defp route_selector(unknown), do: error_response("Unknown selector: #{unknown}")

  # Root menu - Gopher type 1 (directory)
  defp root_menu do
    """
    iWelcome to PureGopherAI Server\t\t#{@server_host}\t#{@server_port}
    i\t\t#{@server_host}\t#{@server_port}
    iPowered by Elixir + Bumblebee + Metal GPU\t\t#{@server_host}\t#{@server_port}
    i\t\t#{@server_host}\t#{@server_port}
    1Ask AI a question\t/ask\t#{@server_host}\t#{@server_port}
    0About this server\t/about\t#{@server_host}\t#{@server_port}
    i\t\t#{@server_host}\t#{@server_port}
    iUsage: Select 'Ask AI' then type your question\t\t#{@server_host}\t#{@server_port}
    .
    """
  end

  # Handle AI query - calls AI engine directly via message passing
  defp handle_ask(query) when byte_size(query) > 0 do
    Logger.info("AI Query: #{query}")

    start_time = System.monotonic_time(:millisecond)
    response = PureGopherAi.AiEngine.generate(query)
    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.info("AI Response generated in #{elapsed}ms")

    format_text_response("""
    Query: #{query}

    Response:
    #{response}

    ---
    Generated in #{elapsed}ms using GPU acceleration
    """)
  end

  defp handle_ask(_), do: error_response("Please provide a query after /ask")

  # About page - server stats
  defp about_page do
    {:ok, hostname} = :inet.gethostname()
    memory = :erlang.memory()
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)
    uptime_min = div(uptime_ms, 60_000)

    backend_info =
      case :os.type() do
        {:unix, :darwin} -> "Torchx (Metal MPS GPU)"
        _ -> "EXLA (CPU)"
      end

    format_text_response("""
    === PureGopherAI Server Stats ===

    Host: #{hostname}
    Port: #{@server_port}
    Protocol: Gopher (RFC 1436)

    Runtime: Elixir #{System.version()} / OTP #{System.otp_release()}
    Uptime: #{uptime_min} minutes
    Memory (Total): #{div(memory[:total], 1_048_576)} MB
    Memory (Processes): #{div(memory[:processes], 1_048_576)} MB

    AI Backend: Bumblebee
    Compute Backend: #{backend_info}
    Model: GPT-2 (openai-community/gpt2)

    TCP Server: ThousandIsland
    Architecture: OTP Supervision Tree
    """)
  end

  # Format as Gopher text response (type 0)
  defp format_text_response(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&("i#{&1}\t\t#{@server_host}\t#{@server_port}"))
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
