defmodule PureGopherAi.ConversationStore do
  @moduledoc """
  Stores conversation history per session for contextual AI responses.
  Uses ETS for fast access with TTL-based expiration.

  Sessions are identified by a hash of the client IP.
  Each session stores the last N messages with timestamps.

  Configurable via:
  - :conversation_max_messages - max messages per session (default: 10)
  - :conversation_ttl_ms - session TTL in ms (default: 3600000 = 1 hour)
  """

  use GenServer
  require Logger

  @table_name :conversation_store
  @cleanup_interval 300_000  # Clean up expired sessions every 5 minutes

  # Client API

  @doc """
  Starts the conversation store GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets or creates a session ID for the given client IP.
  """
  def get_session_id(client_ip) when is_tuple(client_ip) do
    get_session_id(format_ip(client_ip))
  end

  def get_session_id(client_ip) when is_binary(client_ip) do
    :crypto.hash(:sha256, client_ip)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  @doc """
  Adds a message to the conversation history.
  Returns the updated conversation.
  """
  def add_message(session_id, role, content) when role in [:user, :assistant] do
    GenServer.call(__MODULE__, {:add_message, session_id, role, content})
  end

  @doc """
  Gets the conversation history for a session.
  Returns a list of {role, content} tuples.
  """
  def get_history(session_id) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, _updated_at, messages}] ->
        Enum.map(messages, fn {role, content, _ts} -> {role, content} end)

      [] ->
        []
    end
  end

  @doc """
  Gets the conversation as a formatted context string for the AI.
  """
  def get_context(session_id) do
    history = get_history(session_id)

    if history == [] do
      nil
    else
      history
      |> Enum.map(fn
        {:user, content} -> "User: #{content}"
        {:assistant, content} -> "Assistant: #{content}"
      end)
      |> Enum.join("\n")
    end
  end

  @doc """
  Clears the conversation history for a session.
  """
  def clear(session_id) do
    :ets.delete(@table_name, session_id)
    :ok
  end

  @doc """
  Clears all conversation sessions.
  """
  def clear_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Gets the number of active sessions.
  """
  def session_count do
    :ets.info(@table_name, :size)
  end

  @doc """
  Gets the configured max messages per session.
  """
  def max_messages do
    Application.get_env(:pure_gopher_ai, :conversation_max_messages, 10)
  end

  @doc """
  Gets the configured session TTL in milliseconds.
  """
  def ttl_ms do
    Application.get_env(:pure_gopher_ai, :conversation_ttl_ms, 3_600_000)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set])
    schedule_cleanup()
    Logger.info("ConversationStore started: max #{max_messages()} messages, TTL #{div(ttl_ms(), 60_000)} min")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_message, session_id, role, content}, _from, state) do
    now = System.monotonic_time(:millisecond)
    max = max_messages()

    # Get existing messages or start fresh
    messages =
      case :ets.lookup(@table_name, session_id) do
        [{^session_id, _updated_at, msgs}] -> msgs
        [] -> []
      end

    # Add new message and trim to max
    new_message = {role, content, now}
    updated_messages = (messages ++ [new_message]) |> Enum.take(-max)

    # Store updated conversation
    :ets.insert(@table_name, {session_id, now, updated_messages})

    # Return the conversation for context
    conversation =
      Enum.map(updated_messages, fn {r, c, _ts} -> {r, c} end)

    {:reply, {:ok, conversation}, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)
    ttl = ttl_ms()
    cutoff = now - ttl

    expired_count =
      :ets.foldl(
        fn {session_id, updated_at, _messages}, count ->
          if updated_at < cutoff do
            :ets.delete(@table_name, session_id)
            count + 1
          else
            count
          end
        end,
        0,
        @table_name
      )

    if expired_count > 0 do
      Logger.debug("ConversationStore: cleaned up #{expired_count} expired sessions")
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip) when is_binary(ip), do: ip
end
