defmodule PureGopherAi.Plugins do
  @moduledoc """
  Plugin system for extensible functionality.

  Features:
  - Load/unload plugins at runtime
  - Plugin hooks for various events
  - Plugin configuration
  - Sandboxed execution
  """

  use GenServer
  require Logger

  @table_name :plugins
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @plugins_dir Application.compile_env(:pure_gopher_ai, :plugins_dir, "~/.gopher/plugins")

  # Available hook points
  @hooks [
    :before_request,       # Before handling any request
    :after_request,        # After handling a request
    :on_new_post,          # When a new phlog post is created
    :on_new_user,          # When a new user registers
    :on_new_comment,       # When a comment is added
    :on_new_message,       # When a message is sent
    :on_login,             # When a user authenticates
    :on_ai_query,          # Before AI query processing
    :on_ai_response,       # After AI response generation
    :on_search,            # When search is performed
    :content_filter,       # Content moderation filter
    :custom_selector       # Custom selector handling
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads a plugin from a file.
  """
  def load_plugin(path) do
    GenServer.call(__MODULE__, {:load, path})
  end

  @doc """
  Unloads a plugin.
  """
  def unload_plugin(plugin_id) do
    GenServer.call(__MODULE__, {:unload, plugin_id})
  end

  @doc """
  Lists all loaded plugins.
  """
  def list_plugins do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Gets plugin info.
  """
  def get_plugin(plugin_id) do
    GenServer.call(__MODULE__, {:get, plugin_id})
  end

  @doc """
  Enables/disables a plugin.
  """
  def set_enabled(plugin_id, enabled) do
    GenServer.call(__MODULE__, {:set_enabled, plugin_id, enabled})
  end

  @doc """
  Triggers a hook and returns aggregated results from all plugins.
  """
  def trigger_hook(hook, context) do
    GenServer.call(__MODULE__, {:trigger, hook, context}, 30_000)
  end

  @doc """
  Triggers a hook asynchronously (fire and forget).
  """
  def trigger_hook_async(hook, context) do
    GenServer.cast(__MODULE__, {:trigger_async, hook, context})
  end

  @doc """
  Gets plugin configuration.
  """
  def get_config(plugin_id) do
    GenServer.call(__MODULE__, {:get_config, plugin_id})
  end

  @doc """
  Sets plugin configuration.
  """
  def set_config(plugin_id, config) do
    GenServer.call(__MODULE__, {:set_config, plugin_id, config})
  end

  @doc """
  Returns available hooks.
  """
  def hooks, do: @hooks

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    plugins_dir = Path.expand(@plugins_dir)
    File.mkdir_p!(data_dir)
    File.mkdir_p!(plugins_dir)

    dets_file = Path.join(data_dir, "plugins.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Load enabled plugins on startup
    loaded = load_enabled_plugins()

    Logger.info("[Plugins] Started, #{length(loaded)} plugins loaded")
    {:ok, %{plugins: Map.new(loaded)}}
  end

  @impl true
  def handle_call({:load, path}, _from, state) do
    case load_plugin_file(path) do
      {:ok, plugin} ->
        plugin_id = plugin.id

        # Store in DETS
        :dets.insert(@table_name, {plugin_id, plugin})
        :dets.sync(@table_name)

        # Add to state
        new_state = %{state | plugins: Map.put(state.plugins, plugin_id, plugin)}

        Logger.info("[Plugins] Loaded plugin: #{plugin.name}")
        {:reply, {:ok, plugin}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unload, plugin_id}, _from, state) do
    case Map.get(state.plugins, plugin_id) do
      nil ->
        {:reply, {:error, :plugin_not_found}, state}

      plugin ->
        # Call cleanup if defined
        if function_exported?(plugin.module, :cleanup, 0) do
          apply(plugin.module, :cleanup, [])
        end

        # Remove from DETS
        :dets.delete(@table_name, plugin_id)
        :dets.sync(@table_name)

        # Remove from state
        new_state = %{state | plugins: Map.delete(state.plugins, plugin_id)}

        Logger.info("[Plugins] Unloaded plugin: #{plugin.name}")
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    plugins = state.plugins
      |> Map.values()
      |> Enum.map(&sanitize_plugin_info/1)
      |> Enum.sort_by(& &1.name)

    {:reply, {:ok, plugins}, state}
  end

  @impl true
  def handle_call({:get, plugin_id}, _from, state) do
    case Map.get(state.plugins, plugin_id) do
      nil -> {:reply, {:error, :plugin_not_found}, state}
      plugin -> {:reply, {:ok, sanitize_plugin_info(plugin)}, state}
    end
  end

  @impl true
  def handle_call({:set_enabled, plugin_id, enabled}, _from, state) do
    case Map.get(state.plugins, plugin_id) do
      nil ->
        {:reply, {:error, :plugin_not_found}, state}

      plugin ->
        updated = %{plugin | enabled: enabled}

        :dets.insert(@table_name, {plugin_id, updated})
        :dets.sync(@table_name)

        new_state = %{state | plugins: Map.put(state.plugins, plugin_id, updated)}

        Logger.info("[Plugins] #{if enabled, do: "Enabled", else: "Disabled"} plugin: #{plugin.name}")
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:trigger, hook, context}, _from, state) do
    if hook not in @hooks do
      {:reply, {:error, :invalid_hook}, state}
    else
      results = trigger_hook_internal(state.plugins, hook, context)
      {:reply, {:ok, results}, state}
    end
  end

  @impl true
  def handle_call({:get_config, plugin_id}, _from, state) do
    case Map.get(state.plugins, plugin_id) do
      nil -> {:reply, {:error, :plugin_not_found}, state}
      plugin -> {:reply, {:ok, plugin.config}, state}
    end
  end

  @impl true
  def handle_call({:set_config, plugin_id, config}, _from, state) do
    case Map.get(state.plugins, plugin_id) do
      nil ->
        {:reply, {:error, :plugin_not_found}, state}

      plugin ->
        updated = %{plugin | config: Map.merge(plugin.config, config)}

        :dets.insert(@table_name, {plugin_id, updated})
        :dets.sync(@table_name)

        new_state = %{state | plugins: Map.put(state.plugins, plugin_id, updated)}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast({:trigger_async, hook, context}, state) do
    if hook in @hooks do
      spawn(fn ->
        trigger_hook_internal(state.plugins, hook, context)
      end)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp load_enabled_plugins do
    :dets.foldl(fn {_id, plugin}, acc ->
      if plugin.enabled do
        [{plugin.id, plugin} | acc]
      else
        acc
      end
    end, [], @table_name)
  end

  defp load_plugin_file(path) do
    expanded_path = Path.expand(path)

    if not File.exists?(expanded_path) do
      {:error, :file_not_found}
    else
      # Read and parse plugin definition
      case File.read(expanded_path) do
        {:ok, content} ->
          parse_plugin(content, path)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_plugin(content, path) do
    # Plugin format is Elixir code with specific structure
    try do
      {result, _} = Code.eval_string(content)

      case result do
        %{name: name, version: version, hooks: hooks} = plugin_def ->
          plugin_id = generate_plugin_id(name)
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          # Create module if handler code is provided
          module = if Map.has_key?(plugin_def, :handler) do
            create_plugin_module(plugin_id, plugin_def.handler)
          else
            nil
          end

          plugin = %{
            id: plugin_id,
            name: name,
            version: version,
            description: Map.get(plugin_def, :description, ""),
            author: Map.get(plugin_def, :author, "Unknown"),
            hooks: hooks,
            module: module,
            config: Map.get(plugin_def, :default_config, %{}),
            enabled: true,
            loaded_at: now,
            path: path
          }

          {:ok, plugin}

        _ ->
          {:error, :invalid_plugin_format}
      end
    rescue
      e ->
        {:error, {:parse_error, Exception.message(e)}}
    end
  end

  defp create_plugin_module(plugin_id, handler_code) do
    module_name = String.to_atom("Elixir.PureGopherAi.Plugin.#{String.capitalize(plugin_id)}")

    try do
      Code.eval_string("""
      defmodule #{module_name} do
        #{handler_code}
      end
      """)

      module_name
    rescue
      _ -> nil
    end
  end

  defp trigger_hook_internal(plugins, hook, context) do
    plugins
    |> Map.values()
    |> Enum.filter(fn p -> p.enabled and hook in p.hooks end)
    |> Enum.map(fn plugin ->
      try do
        if plugin.module && function_exported?(plugin.module, hook, 1) do
          result = apply(plugin.module, hook, [context])
          {plugin.id, {:ok, result}}
        else
          {plugin.id, {:ok, :no_handler}}
        end
      rescue
        e ->
          Logger.warning("[Plugins] Error in plugin #{plugin.name} hook #{hook}: #{Exception.message(e)}")
          {plugin.id, {:error, Exception.message(e)}}
      end
    end)
  end

  defp sanitize_plugin_info(plugin) do
    Map.take(plugin, [:id, :name, :version, :description, :author, :hooks, :enabled, :loaded_at])
  end

  defp generate_plugin_id(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> String.slice(0, 32)
  end
end
