defmodule PureGopherAi.TorManager do
  @moduledoc """
  Manages a Tor hidden service process on Nerves (Raspberry Pi).

  On Nerves targets, there is no system Tor daemon — this GenServer manages
  the entire Tor lifecycle:

  1. Writes a `torrc` config to `/data/tor/torrc`
  2. Starts a static Tor binary via `Port.open/2`
  3. Monitors the process and restarts on crash
  4. Reads the generated `.onion` hostname from `/data/tor/hidden_service/hostname`
  5. Updates the application config with the discovered onion address

  ## Prerequisites

  A statically compiled Tor binary for armv7l must be placed at
  `rootfs_overlay/usr/bin/tor` before building firmware. This gets baked
  into the Nerves firmware image.

  ## Configuration

      config :pure_gopher_ai,
        tor_enabled: true,
        tor_port: 7071,
        tor_data_dir: "/data/tor"

  ## Directory Structure on Pi

      /data/tor/
      ├── torrc                  # Generated config
      ├── hidden_service/        # Created by Tor
      │   ├── hostname           # .onion address
      │   └── private_key        # Service key
      └── logs/
          └── tor.log            # Tor process log
  """

  use GenServer
  require Logger

  @tor_binary "/usr/bin/tor"
  @default_data_dir "/data/tor"
  @hostname_poll_interval 2_000
  @max_hostname_attempts 30
  @restart_delay 5_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the discovered .onion address, or nil if not yet available.
  """
  def onion_address do
    GenServer.call(__MODULE__, :onion_address)
  end

  @doc """
  Returns the current status of the Tor process.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Restarts the Tor process.
  """
  def restart do
    GenServer.cast(__MODULE__, :restart)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    state = %{
      port: nil,
      onion_address: nil,
      status: :starting,
      data_dir: data_dir(),
      tor_port: Application.get_env(:pure_gopher_ai, :tor_port, 7071),
      restart_count: 0
    }

    # Start Tor asynchronously
    send(self(), :start_tor)

    {:ok, state}
  end

  @impl true
  def handle_call(:onion_address, _from, state) do
    {:reply, state.onion_address, state}
  end

  def handle_call(:status, _from, state) do
    info = %{
      status: state.status,
      onion_address: state.onion_address,
      restart_count: state.restart_count,
      data_dir: state.data_dir
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:restart, state) do
    state = stop_tor(state)
    send(self(), :start_tor)
    {:noreply, %{state | status: :restarting}}
  end

  @impl true
  def handle_info(:start_tor, state) do
    case start_tor_process(state) do
      {:ok, new_state} ->
        Logger.info("TorManager: Tor process started")
        # Start polling for hostname file
        send(self(), {:poll_hostname, 0})
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("TorManager: Failed to start Tor: #{inspect(reason)}")
        # Retry after delay
        Process.send_after(self(), :start_tor, @restart_delay)
        {:noreply, %{state | status: :failed}}
    end
  end

  def handle_info({:poll_hostname, attempt}, state) do
    hostname_file = Path.join([state.data_dir, "hidden_service", "hostname"])

    cond do
      attempt >= @max_hostname_attempts ->
        Logger.warning("TorManager: Timed out waiting for .onion hostname (#{attempt} attempts)")
        {:noreply, %{state | status: :running_no_hostname}}

      File.exists?(hostname_file) ->
        case File.read(hostname_file) do
          {:ok, content} ->
            address = String.trim(content)
            Logger.info("TorManager: Onion address discovered: #{address}")

            # Update application config so other modules can use it
            Application.put_env(:pure_gopher_ai, :onion_address, address)

            # Re-init persistent terms so Config.onion_address() returns the new value
            try do
              PureGopherAi.Config.init()
            rescue
              _ -> :ok
            end

            {:noreply, %{state | onion_address: address, status: :running}}

          {:error, reason} ->
            Logger.warning("TorManager: Cannot read hostname file: #{inspect(reason)}")
            Process.send_after(self(), {:poll_hostname, attempt + 1}, @hostname_poll_interval)
            {:noreply, state}
        end

      true ->
        Process.send_after(self(), {:poll_hostname, attempt + 1}, @hostname_poll_interval)
        {:noreply, state}
    end
  end

  # Tor process sent data to stdout/stderr
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    message = to_string(data) |> String.trim()

    if message != "" do
      Logger.debug("TorManager [tor]: #{message}")
    end

    {:noreply, state}
  end

  # Tor process exited
  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    Logger.warning("TorManager: Tor process exited with code #{exit_code}")

    new_state = %{state |
      port: nil,
      status: :stopped,
      restart_count: state.restart_count + 1
    }

    # Auto-restart after delay
    Process.send_after(self(), :start_tor, @restart_delay)
    {:noreply, new_state}
  end

  # Handle unexpected port close
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("TorManager: Tor port closed: #{inspect(reason)}")
    new_state = %{state | port: nil, status: :stopped}
    Process.send_after(self(), :start_tor, @restart_delay)
    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_tor(state)
    :ok
  end

  # --- Private Functions ---

  defp start_tor_process(state) do
    data_dir = state.data_dir
    tor_port = state.tor_port

    # Ensure directories exist
    hidden_service_dir = Path.join(data_dir, "hidden_service")
    log_dir = Path.join(data_dir, "logs")

    Enum.each([data_dir, hidden_service_dir, log_dir], fn dir ->
      File.mkdir_p!(dir)
    end)

    # Tor requires strict permissions on the hidden service directory
    File.chmod!(hidden_service_dir, 0o700)

    # Write torrc
    torrc_path = Path.join(data_dir, "torrc")
    write_torrc(torrc_path, data_dir, tor_port)

    # Check that the Tor binary exists
    if not File.exists?(@tor_binary) do
      {:error, :tor_binary_not_found}
    else
      # Start Tor process
      port =
        Port.open(
          {:spawn_executable, @tor_binary},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-f", torrc_path]
          ]
        )

      {:ok, %{state | port: port, status: :starting}}
    end
  end

  defp write_torrc(path, data_dir, tor_port) do
    hidden_service_dir = Path.join(data_dir, "hidden_service")
    log_file = Path.join(data_dir, "logs/tor.log")

    # Get the Gopher port that the Tor hidden service should expose
    gopher_port = Application.get_env(:pure_gopher_ai, :clearnet_port, 70)

    content = """
    # Auto-generated by PureGopherAI TorManager
    # Do not edit manually - changes will be overwritten on restart

    DataDirectory #{data_dir}
    Log notice file #{log_file}

    # Hidden service configuration
    HiddenServiceDir #{hidden_service_dir}
    HiddenServicePort #{gopher_port} 127.0.0.1:#{tor_port}

    # Gemini protocol (if enabled)
    #{gemini_hidden_service_line()}

    # Safety settings
    SocksPort 0
    """

    File.write!(path, content)
    Logger.debug("TorManager: Wrote torrc to #{path}")
  end

  defp gemini_hidden_service_line do
    if Application.get_env(:pure_gopher_ai, :gemini_enabled, false) do
      gemini_port = Application.get_env(:pure_gopher_ai, :gemini_port, 1965)
      "HiddenServicePort #{gemini_port} 127.0.0.1:#{gemini_port}"
    else
      "# Gemini not enabled"
    end
  end

  defp stop_tor(%{port: nil} = state), do: state

  defp stop_tor(%{port: port} = state) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    %{state | port: nil, status: :stopped}
  end

  defp data_dir do
    Application.get_env(:pure_gopher_ai, :tor_data_dir, @default_data_dir)
  end
end
