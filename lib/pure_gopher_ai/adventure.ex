defmodule PureGopherAi.Adventure do
  @moduledoc """
  AI-powered interactive text adventure game.

  Features:
  - Session-based game state (ETS)
  - AI-generated story and choices
  - Multiple genre support
  - Inventory and stats system
  - Save/load game state
  """

  use GenServer
  require Logger

  alias PureGopherAi.AiEngine

  @table_name :adventure_sessions
  @session_ttl_ms 7_200_000  # 2 hours

  @genres %{
    "fantasy" => %{
      name: "Fantasy",
      description: "Magic, dragons, and epic quests in medieval lands",
      setting: "a magical medieval kingdom filled with wizards, dragons, and ancient mysteries"
    },
    "scifi" => %{
      name: "Science Fiction",
      description: "Space exploration, alien encounters, and future tech",
      setting: "a vast galaxy with advanced technology, alien civilizations, and unexplored worlds"
    },
    "mystery" => %{
      name: "Mystery",
      description: "Detective work, clues, and solving crimes",
      setting: "a noir city where you are a detective investigating strange and dangerous cases"
    },
    "horror" => %{
      name: "Horror",
      description: "Supernatural terror and survival",
      setting: "a dark and terrifying world where supernatural horrors lurk in every shadow"
    },
    "cyberpunk" => %{
      name: "Cyberpunk",
      description: "High tech, low life in neon-lit megacities",
      setting: "a dystopian megacity of neon lights, corporate corruption, and underground hackers"
    },
    "western" => %{
      name: "Western",
      description: "Frontier adventures in the Old West",
      setting: "the lawless frontier of the Old West with outlaws, sheriffs, and dusty towns"
    },
    "pirate" => %{
      name: "Pirate",
      description: "High seas adventure and treasure hunting",
      setting: "the Caribbean seas during the golden age of piracy with treasure, ships, and adventure"
    },
    "survival" => %{
      name: "Survival",
      description: "Fight to survive in hostile environments",
      setting: "a harsh wilderness where you must use your wits to survive against nature and threats"
    }
  }

  @default_stats %{
    health: 100,
    strength: 10,
    intelligence: 10,
    luck: 10
  }

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Lists available genres.
  """
  def genres, do: @genres

  @doc """
  Gets the current game state for a session.
  """
  def get_session(session_id) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, state, _timestamp}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Starts a new game for a session.
  """
  def new_game(session_id, genre \\ "fantasy") do
    GenServer.call(__MODULE__, {:new_game, session_id, genre}, 60_000)
  end

  @doc """
  Takes an action in the game.
  """
  def take_action(session_id, action) do
    GenServer.call(__MODULE__, {:action, session_id, action}, 60_000)
  end

  @doc """
  Looks around the current location.
  """
  def look(session_id) do
    GenServer.call(__MODULE__, {:look, session_id}, 60_000)
  end

  @doc """
  Gets the player's inventory.
  """
  def inventory(session_id) do
    case get_session(session_id) do
      {:ok, state} -> {:ok, state.inventory}
      error -> error
    end
  end

  @doc """
  Gets the player's stats.
  """
  def stats(session_id) do
    case get_session(session_id) do
      {:ok, state} -> {:ok, state.stats}
      error -> error
    end
  end

  @doc """
  Saves the current game state (returns a save code).
  """
  def save_game(session_id) do
    case get_session(session_id) do
      {:ok, state} ->
        save_data = :erlang.term_to_binary(state) |> Base.encode64()
        {:ok, save_data}
      error -> error
    end
  end

  @doc """
  Loads a saved game from a save code.
  """
  def load_game(session_id, save_code) do
    try do
      state = Base.decode64!(save_code) |> :erlang.binary_to_term()
      :ets.insert(@table_name, {session_id, state, System.system_time(:millisecond)})
      {:ok, state}
    rescue
      _ -> {:error, :invalid_save}
    end
  end

  @doc """
  Streams an action with callback for real-time output.
  """
  def take_action_stream(session_id, action, callback) do
    GenServer.call(__MODULE__, {:action_stream, session_id, action, callback}, 120_000)
  end

  @doc """
  Starts a new game with streaming output.
  """
  def new_game_stream(session_id, genre, callback) do
    GenServer.call(__MODULE__, {:new_game_stream, session_id, genre, callback}, 120_000)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    Logger.info("Adventure: Game system initialized")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:new_game, session_id, genre}, _from, state) do
    result = start_new_game(session_id, genre, false, nil)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:new_game_stream, session_id, genre, callback}, _from, state) do
    result = start_new_game(session_id, genre, true, callback)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:action, session_id, action}, _from, state) do
    result = process_action(session_id, action, false, nil)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:action_stream, session_id, action, callback}, _from, state) do
    result = process_action(session_id, action, true, callback)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:look, session_id}, _from, state) do
    result = look_around(session_id)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions

  defp start_new_game(session_id, genre_key, stream?, callback) do
    genre = Map.get(@genres, genre_key, @genres["fantasy"])

    initial_state = %{
      genre: genre_key,
      genre_name: genre.name,
      turn: 0,
      history: [],
      inventory: ["worn backpack", "small knife", "flint and steel"],
      stats: @default_stats,
      location: "unknown",
      alive: true
    }

    prompt = """
    You are the narrator of an interactive text adventure game set in #{genre.setting}.

    Start a new adventure! Create an engaging opening scene that:
    1. Establishes the setting vividly in 2-3 sentences
    2. Introduces the player's character briefly
    3. Presents an immediate choice or challenge
    4. End with 2-3 clear numbered options

    Keep response under 150 words. Be descriptive but concise.
    """

    case generate_response(prompt, stream?, callback) do
      {:ok, response} ->
        game_state = %{initial_state |
          history: [{:narrator, response}],
          turn: 1
        }
        :ets.insert(@table_name, {session_id, game_state, System.system_time(:millisecond)})
        {:ok, game_state, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_action(session_id, action, stream?, callback) do
    case get_session(session_id) do
      {:ok, state} when state.alive ->
        # Build context from history
        history_context = state.history
          |> Enum.take(-6)  # Last 3 exchanges
          |> Enum.map(fn
            {:player, text} -> "Player: #{text}"
            {:narrator, text} -> "Narrator: #{text}"
          end)
          |> Enum.join("\n\n")

        genre = Map.get(@genres, state.genre, @genres["fantasy"])

        prompt = """
        You are the narrator of a text adventure in #{genre.setting}.
        Player items: #{Enum.join(Enum.take(state.inventory, 3), ", ")}
        Health: #{state.stats.health}/100

        Recent story: #{String.slice(history_context, 0..300)}

        Player action: #{action}

        Respond with what happens (under 100 words) and 2-3 numbered options.
        """

        case generate_response(prompt, stream?, callback) do
          {:ok, response} ->
            # Parse for inventory changes and stat updates
            {new_inventory, new_stats, is_alive} = parse_game_effects(response, state)

            new_state = %{state |
              history: state.history ++ [{:player, action}, {:narrator, response}],
              turn: state.turn + 1,
              inventory: new_inventory,
              stats: new_stats,
              alive: is_alive
            }

            :ets.insert(@table_name, {session_id, new_state, System.system_time(:millisecond)})
            {:ok, new_state, response}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _state} ->
        {:error, :game_over}

      {:error, :not_found} ->
        {:error, :no_game}
    end
  end

  defp look_around(session_id) do
    case get_session(session_id) do
      {:ok, state} ->
        last_narrator = state.history
          |> Enum.filter(fn {type, _} -> type == :narrator end)
          |> List.last()

        case last_narrator do
          {:narrator, text} -> {:ok, text}
          nil -> {:error, :no_context}
        end

      error -> error
    end
  end

  defp generate_response(prompt, false = _stream?, _callback) do
    case AiEngine.generate(prompt, max_new_tokens: 400) do
      {:ok, response} -> {:ok, String.trim(response)}
      error -> error
    end
  end

  defp generate_response(prompt, true = _stream?, callback) do
    # generate_stream returns a plain string, not a tuple
    result = AiEngine.generate_stream(prompt, nil, fn chunk ->
      callback.(chunk)
      chunk
    end)

    # Return {:ok, response} to match non-streaming API
    case result do
      response when is_binary(response) and response != "" ->
        {:ok, String.trim(response)}

      "" ->
        {:error, :no_response}

      {:error, _} = error ->
        error

      _ ->
        {:error, :unknown_error}
    end
  end

  defp parse_game_effects(response, state) do
    response_lower = String.downcase(response)

    # Simple inventory detection
    new_inventory = cond do
      String.contains?(response_lower, "you find a ") or
      String.contains?(response_lower, "you pick up ") or
      String.contains?(response_lower, "you obtain ") ->
        # Try to extract item - simple pattern
        case Regex.run(~r/you (?:find|pick up|obtain) (?:a |an |the )?([a-z\s]+?)(?:\.|,|!|\z)/i, response) do
          [_, item] -> [String.trim(item) | state.inventory] |> Enum.take(20)
          _ -> state.inventory
        end
      true ->
        state.inventory
    end

    # Health detection
    new_health = cond do
      String.contains?(response_lower, "you take damage") or
      String.contains?(response_lower, "you are hurt") or
      String.contains?(response_lower, "wounds you") ->
        max(0, state.stats.health - :rand.uniform(20))
      String.contains?(response_lower, "you heal") or
      String.contains?(response_lower, "restored") ->
        min(100, state.stats.health + :rand.uniform(20))
      true ->
        state.stats.health
    end

    new_stats = %{state.stats | health: new_health}

    # Check if dead
    is_alive = cond do
      new_health <= 0 -> false
      String.contains?(response_lower, "you die") or
      String.contains?(response_lower, "you are dead") or
      String.contains?(response_lower, "game over") -> false
      true -> true
    end

    {new_inventory, new_stats, is_alive}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 300_000)  # Every 5 minutes
  end

  defp cleanup_expired do
    now = System.system_time(:millisecond)
    cutoff = now - @session_ttl_ms

    expired = :ets.foldl(fn
      {session_id, _state, timestamp}, acc when timestamp < cutoff ->
        [session_id | acc]
      _, acc ->
        acc
    end, [], @table_name)

    Enum.each(expired, &:ets.delete(@table_name, &1))

    if length(expired) > 0 do
      Logger.debug("Adventure: Cleaned up #{length(expired)} expired sessions")
    end
  end
end
