defmodule PureGopherAi.Games do
  @moduledoc """
  Simple games for the Gopher community.

  Games:
  - Hangman: Guess the word letter by letter
  - Number Guess: Guess the secret number
  - Word Scramble: Unscramble the word
  """

  use GenServer
  require Logger

  @session_ttl_ms 3_600_000  # 1 hour

  # Word list for Hangman and Word Scramble
  @words [
    # Technology
    "computer", "keyboard", "internet", "software", "hardware", "database",
    "algorithm", "compiler", "terminal", "network", "protocol", "server",
    # Animals
    "elephant", "giraffe", "penguin", "dolphin", "octopus", "kangaroo",
    # Objects
    "umbrella", "telescope", "calendar", "mountain", "bicycle", "fountain",
    # Abstract
    "freedom", "mystery", "harmony", "journey", "courage", "wisdom"
  ]

  @max_guesses 6

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a new Hangman game.
  """
  def start_hangman(session_id) do
    GenServer.call(__MODULE__, {:start_hangman, session_id})
  end

  @doc """
  Makes a guess in Hangman.
  """
  def guess_letter(session_id, letter) do
    GenServer.call(__MODULE__, {:guess_letter, session_id, letter})
  end

  @doc """
  Gets current Hangman game state.
  """
  def hangman_state(session_id) do
    GenServer.call(__MODULE__, {:hangman_state, session_id})
  end

  @doc """
  Starts a new Number Guess game.
  """
  def start_number_guess(session_id, max \\ 100) do
    GenServer.call(__MODULE__, {:start_number_guess, session_id, max})
  end

  @doc """
  Makes a guess in Number Guess.
  """
  def guess_number(session_id, number) do
    GenServer.call(__MODULE__, {:guess_number, session_id, number})
  end

  @doc """
  Gets current Number Guess game state.
  """
  def number_guess_state(session_id) do
    GenServer.call(__MODULE__, {:number_guess_state, session_id})
  end

  @doc """
  Starts a new Word Scramble game.
  """
  def start_scramble(session_id) do
    GenServer.call(__MODULE__, {:start_scramble, session_id})
  end

  @doc """
  Makes a guess in Word Scramble.
  """
  def guess_word(session_id, word) do
    GenServer.call(__MODULE__, {:guess_word, session_id, word})
  end

  @doc """
  Gets current Word Scramble state.
  """
  def scramble_state(session_id) do
    GenServer.call(__MODULE__, {:scramble_state, session_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(:games_sessions, [:named_table, :public, :set])

    # Schedule cleanup
    schedule_cleanup()

    Logger.info("[Games] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_hangman, session_id}, _from, state) do
    word = Enum.random(@words)

    game = %{
      type: :hangman,
      word: word,
      guessed: MapSet.new(),
      wrong_guesses: 0,
      status: :playing,
      started_at: System.system_time(:millisecond)
    }

    :ets.insert(:games_sessions, {{:hangman, session_id}, game})

    display = mask_word(word, game.guessed)
    {:reply, {:ok, %{display: display, remaining: @max_guesses}}, state}
  end

  @impl true
  def handle_call({:guess_letter, session_id, letter}, _from, state) do
    letter = letter |> String.trim() |> String.downcase() |> String.first()

    case :ets.lookup(:games_sessions, {:hangman, session_id}) do
      [{{:hangman, ^session_id}, game}] when game.status == :playing ->
        if is_nil(letter) or not (letter >= "a" and letter <= "z") do
          {:reply, {:error, :invalid_letter}, state}
        else
          if MapSet.member?(game.guessed, letter) do
            {:reply, {:error, :already_guessed}, state}
          else
            guessed = MapSet.put(game.guessed, letter)
            in_word = String.contains?(game.word, letter)

            wrong_guesses = if in_word, do: game.wrong_guesses, else: game.wrong_guesses + 1

            display = mask_word(game.word, guessed)
            won = not String.contains?(display, "_")
            lost = wrong_guesses >= @max_guesses

            status = cond do
              won -> :won
              lost -> :lost
              true -> :playing
            end

            updated_game = %{game |
              guessed: guessed,
              wrong_guesses: wrong_guesses,
              status: status
            }

            :ets.insert(:games_sessions, {{:hangman, session_id}, updated_game})

            result = %{
              letter: letter,
              correct: in_word,
              display: display,
              wrong_guesses: wrong_guesses,
              remaining: @max_guesses - wrong_guesses,
              status: status,
              word: if(status != :playing, do: game.word, else: nil),
              guessed_letters: MapSet.to_list(guessed) |> Enum.sort()
            }

            {:reply, {:ok, result}, state}
          end
        end

      [{{:hangman, ^session_id}, game}] ->
        {:reply, {:error, :game_over, game.status, game.word}, state}

      [] ->
        {:reply, {:error, :no_game}, state}
    end
  end

  @impl true
  def handle_call({:hangman_state, session_id}, _from, state) do
    case :ets.lookup(:games_sessions, {:hangman, session_id}) do
      [{{:hangman, ^session_id}, game}] ->
        display = mask_word(game.word, game.guessed)
        result = %{
          display: display,
          wrong_guesses: game.wrong_guesses,
          remaining: @max_guesses - game.wrong_guesses,
          status: game.status,
          word: if(game.status != :playing, do: game.word, else: nil),
          guessed_letters: MapSet.to_list(game.guessed) |> Enum.sort()
        }
        {:reply, {:ok, result}, state}

      [] ->
        {:reply, {:error, :no_game}, state}
    end
  end

  @impl true
  def handle_call({:start_number_guess, session_id, max}, _from, state) do
    secret = :rand.uniform(max)

    game = %{
      type: :number_guess,
      secret: secret,
      max: max,
      guesses: [],
      status: :playing,
      started_at: System.system_time(:millisecond)
    }

    :ets.insert(:games_sessions, {{:number_guess, session_id}, game})

    {:reply, {:ok, %{max: max, attempts: 0}}, state}
  end

  @impl true
  def handle_call({:guess_number, session_id, number}, _from, state) do
    case :ets.lookup(:games_sessions, {:number_guess, session_id}) do
      [{{:number_guess, ^session_id}, game}] when game.status == :playing ->
        cond do
          not is_integer(number) or number < 1 or number > game.max ->
            {:reply, {:error, :invalid_number}, state}

          number in game.guesses ->
            {:reply, {:error, :already_guessed}, state}

          true ->
            guesses = [number | game.guesses]
            correct = number == game.secret

            hint = cond do
              correct -> :correct
              number < game.secret -> :higher
              number > game.secret -> :lower
            end

            status = if correct, do: :won, else: :playing

            updated_game = %{game |
              guesses: guesses,
              status: status
            }

            :ets.insert(:games_sessions, {{:number_guess, session_id}, updated_game})

            result = %{
              guess: number,
              hint: hint,
              attempts: length(guesses),
              status: status,
              secret: if(correct, do: game.secret, else: nil)
            }

            {:reply, {:ok, result}, state}
        end

      [{{:number_guess, ^session_id}, game}] ->
        {:reply, {:error, :game_over, game.status, game.secret}, state}

      [] ->
        {:reply, {:error, :no_game}, state}
    end
  end

  @impl true
  def handle_call({:number_guess_state, session_id}, _from, state) do
    case :ets.lookup(:games_sessions, {:number_guess, session_id}) do
      [{{:number_guess, ^session_id}, game}] ->
        result = %{
          max: game.max,
          attempts: length(game.guesses),
          guesses: Enum.reverse(game.guesses),
          status: game.status,
          secret: if(game.status != :playing, do: game.secret, else: nil)
        }
        {:reply, {:ok, result}, state}

      [] ->
        {:reply, {:error, :no_game}, state}
    end
  end

  @impl true
  def handle_call({:start_scramble, session_id}, _from, state) do
    word = Enum.random(@words)
    scrambled = scramble(word)

    # Make sure scrambled is actually different
    scrambled = if scrambled == word, do: scramble(word), else: scrambled

    game = %{
      type: :scramble,
      word: word,
      scrambled: scrambled,
      attempts: 0,
      status: :playing,
      started_at: System.system_time(:millisecond)
    }

    :ets.insert(:games_sessions, {{:scramble, session_id}, game})

    {:reply, {:ok, %{scrambled: scrambled}}, state}
  end

  @impl true
  def handle_call({:guess_word, session_id, word}, _from, state) do
    word = word |> String.trim() |> String.downcase()

    case :ets.lookup(:games_sessions, {:scramble, session_id}) do
      [{{:scramble, ^session_id}, game}] when game.status == :playing ->
        attempts = game.attempts + 1
        correct = word == game.word

        status = if correct, do: :won, else: :playing

        updated_game = %{game |
          attempts: attempts,
          status: status
        }

        :ets.insert(:games_sessions, {{:scramble, session_id}, updated_game})

        result = %{
          guess: word,
          correct: correct,
          attempts: attempts,
          status: status,
          word: if(correct, do: game.word, else: nil),
          scrambled: game.scrambled
        }

        {:reply, {:ok, result}, state}

      [{{:scramble, ^session_id}, game}] ->
        {:reply, {:error, :game_over, game.status, game.word}, state}

      [] ->
        {:reply, {:error, :no_game}, state}
    end
  end

  @impl true
  def handle_call({:scramble_state, session_id}, _from, state) do
    case :ets.lookup(:games_sessions, {:scramble, session_id}) do
      [{{:scramble, ^session_id}, game}] ->
        result = %{
          scrambled: game.scrambled,
          attempts: game.attempts,
          status: game.status,
          word: if(game.status != :playing, do: game.word, else: nil)
        }
        {:reply, {:ok, result}, state}

      [] ->
        {:reply, {:error, :no_game}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp mask_word(word, guessed) do
    word
    |> String.graphemes()
    |> Enum.map(fn char ->
      if MapSet.member?(guessed, char), do: char, else: "_"
    end)
    |> Enum.join(" ")
  end

  defp scramble(word) do
    word
    |> String.graphemes()
    |> Enum.shuffle()
    |> Enum.join()
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 300_000)  # Every 5 minutes
  end

  defp cleanup_expired_sessions do
    cutoff = System.system_time(:millisecond) - @session_ttl_ms

    expired = :ets.foldl(fn
      {key, game}, acc when is_map(game) ->
        if Map.get(game, :started_at, 0) < cutoff, do: [key | acc], else: acc
      _, acc -> acc
    end, [], :games_sessions)

    Enum.each(expired, fn key ->
      :ets.delete(:games_sessions, key)
    end)
  end
end
