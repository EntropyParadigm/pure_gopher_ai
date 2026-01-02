defmodule PureGopherAi.Tunnel do
  @moduledoc """
  Burrow tunnel integration for PureGopherAI.

  Exposes local Gopher/Gemini/Finger services to the internet via a relay server
  without opening ports on the local machine.

  ## Configuration

      config :pure_gopher_ai, :tunnel,
        enabled: true,
        server: "relay.example.com:4000",
        token: System.get_env("BURROW_TOKEN"),
        tunnels: [
          [name: "gopher", local: 70, remote: 70],
          [name: "gemini", local: 1965, remote: 1965],
          [name: "finger", local: 79, remote: 79]
        ],
        reconnect: true

  ## Environment Variables

  - `BURROW_SERVER` - Relay server address (host:port)
  - `BURROW_TOKEN` - Authentication token

  ## Usage

  Once configured, the tunnel starts automatically with the application.
  Your services will be accessible via the relay server's public IP/domain.
  """

  use GenServer
  require Logger

  defstruct [:client, :config, :status, :connected_at, :tunnels]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current tunnel status.
  """
  def status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status)
    else
      %{enabled: false, status: :disabled}
    end
  end

  @doc """
  Manually reconnect to the relay server.
  """
  def reconnect do
    GenServer.cast(__MODULE__, :reconnect)
  end

  @doc """
  Check if tunneling is enabled in config.
  """
  def enabled? do
    config = Application.get_env(:pure_gopher_ai, :tunnel, [])
    Keyword.get(config, :enabled, false)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Trap exits so linked Burrow.Client doesn't crash us
    Process.flag(:trap_exit, true)

    config = Application.get_env(:pure_gopher_ai, :tunnel, [])

    if Keyword.get(config, :enabled, false) do
      # Schedule connection attempt
      send(self(), :connect)

      {:ok, %__MODULE__{
        client: nil,
        config: config,
        status: :connecting,
        connected_at: nil,
        tunnels: []
      }}
    else
      Logger.info("[Tunnel] Disabled - set tunnel.enabled = true to enable")
      {:ok, %__MODULE__{status: :disabled, config: config}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.status != :disabled,
      status: state.status,
      connected_at: state.connected_at,
      tunnels: state.tunnels,
      server: Keyword.get(state.config, :server)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    if state.client do
      # Disconnect existing client
      try do
        GenServer.stop(state.client)
      catch
        :exit, _ -> :ok
      end
    end

    send(self(), :connect)
    {:noreply, %{state | client: nil, status: :reconnecting}}
  end

  @impl true
  def handle_info(:connect, state) do
    server = get_server(state.config)
    token = get_token(state.config)
    tunnels = Keyword.get(state.config, :tunnels) || default_tunnels()

    cond do
      is_nil(server) ->
        Logger.warning("[Tunnel] No server configured - set BURROW_SERVER or tunnel.server")
        {:noreply, %{state | status: :error}}

      is_nil(token) ->
        Logger.warning("[Tunnel] No token configured - set BURROW_TOKEN or tunnel.token")
        {:noreply, %{state | status: :error}}

      true ->
        Logger.info("[Tunnel] Connecting to #{server}...")

        try do
          case Burrow.connect(server, token: token, tunnels: tunnels) do
            {:ok, client} ->
              Logger.info("[Tunnel] Connected to #{server}")

              Enum.each(tunnels, fn t ->
                Logger.info("[Tunnel]   #{t[:name]}: localhost:#{t[:local]} -> remote:#{t[:remote]}")
              end)

              # Monitor the client process
              Process.monitor(client)

              {:noreply, %{state |
                client: client,
                status: :connected,
                connected_at: DateTime.utc_now(),
                tunnels: tunnels
              }}

            {:error, reason} ->
              Logger.error("[Tunnel] Failed to connect: #{inspect(reason)}")

              # Retry after delay if reconnect is enabled
              if Keyword.get(state.config, :reconnect, true) do
                Process.send_after(self(), :connect, 5_000)
              end

              {:noreply, %{state | status: :error}}
          end
        catch
          kind, reason ->
            Logger.error("[Tunnel] Connection crashed: #{kind} - #{inspect(reason)}")

            # Retry after delay if reconnect is enabled
            if Keyword.get(state.config, :reconnect, true) do
              Process.send_after(self(), :connect, 5_000)
            end

            {:noreply, %{state | status: :error}}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    if pid == state.client do
      Logger.warning("[Tunnel] Connection lost: #{inspect(reason)}")

      # Reconnect if enabled
      if Keyword.get(state.config, :reconnect, true) do
        Process.send_after(self(), :connect, 5_000)
        {:noreply, %{state | client: nil, status: :reconnecting}}
      else
        {:noreply, %{state | client: nil, status: :disconnected}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    if pid == state.client do
      Logger.warning("[Tunnel] Client exited: #{inspect(reason)}")

      # Reconnect if enabled
      if Keyword.get(state.config, :reconnect, true) do
        Process.send_after(self(), :connect, 5_000)
        {:noreply, %{state | client: nil, status: :reconnecting}}
      else
        {:noreply, %{state | client: nil, status: :disconnected}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp get_server(config) do
    Keyword.get(config, :server) || System.get_env("BURROW_SERVER")
  end

  defp get_token(config) do
    case Keyword.get(config, :token) do
      {:system, var} -> System.get_env(var)
      nil -> System.get_env("BURROW_TOKEN")
      token -> token
    end
  end

  defp default_tunnels do
    # Build tunnels based on what's enabled
    tunnels = []

    # Gopher (always enabled)
    clearnet_port = Application.get_env(:pure_gopher_ai, :clearnet_port, 70)
    tunnels = [[name: "gopher", local: clearnet_port, remote: 70] | tunnels]

    # Gemini (if enabled)
    tunnels =
      if Application.get_env(:pure_gopher_ai, :gemini_enabled, false) do
        gemini_port = Application.get_env(:pure_gopher_ai, :gemini_port, 1965)
        [[name: "gemini", local: gemini_port, remote: 1965] | tunnels]
      else
        tunnels
      end

    # Finger (if enabled)
    tunnels =
      if Application.get_env(:pure_gopher_ai, :finger_enabled, false) do
        finger_port = Application.get_env(:pure_gopher_ai, :finger_port, 79)
        [[name: "finger", local: finger_port, remote: 79] | tunnels]
      else
        tunnels
      end

    Enum.reverse(tunnels)
  end
end
