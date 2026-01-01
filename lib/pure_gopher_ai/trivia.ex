defmodule PureGopherAi.Trivia do
  @moduledoc """
  Trivia / Quiz game for the Gopher community.

  Features:
  - Multiple categories
  - Session-based scoring
  - Leaderboard
  - Daily challenges
  """

  use GenServer
  require Logger

  @table_name :trivia_scores
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @session_ttl_ms 3_600_000  # 1 hour

  # Trivia questions database
  @questions [
    # Science
    %{category: "science", question: "What is the chemical symbol for gold?", answer: "au", options: ["Au", "Ag", "Fe", "Cu"]},
    %{category: "science", question: "How many planets are in our solar system?", answer: "8", options: ["7", "8", "9", "10"]},
    %{category: "science", question: "What is the hardest natural substance?", answer: "diamond", options: ["Diamond", "Iron", "Titanium", "Quartz"]},
    %{category: "science", question: "What gas do plants absorb from the atmosphere?", answer: "carbon dioxide", options: ["Oxygen", "Nitrogen", "Carbon Dioxide", "Hydrogen"]},
    %{category: "science", question: "What is the speed of light in km/s (approximately)?", answer: "300000", options: ["150,000", "300,000", "500,000", "1,000,000"]},

    # Technology
    %{category: "technology", question: "What does CPU stand for?", answer: "central processing unit", options: ["Central Processing Unit", "Computer Personal Unit", "Central Program Utility", "Core Processing Unit"]},
    %{category: "technology", question: "Who created Linux?", answer: "linus torvalds", options: ["Bill Gates", "Steve Jobs", "Linus Torvalds", "Dennis Ritchie"]},
    %{category: "technology", question: "What year was the World Wide Web invented?", answer: "1989", options: ["1985", "1989", "1991", "1995"]},
    %{category: "technology", question: "What does HTML stand for?", answer: "hypertext markup language", options: ["HyperText Markup Language", "High Tech Modern Language", "HyperTransfer Machine Language", "Home Tool Markup Language"]},
    %{category: "technology", question: "What was the first programmable computer called?", answer: "eniac", options: ["UNIVAC", "ENIAC", "MARK I", "Colossus"]},

    # History
    %{category: "history", question: "In what year did World War II end?", answer: "1945", options: ["1943", "1944", "1945", "1946"]},
    %{category: "history", question: "Who was the first President of the United States?", answer: "george washington", options: ["Thomas Jefferson", "John Adams", "George Washington", "Benjamin Franklin"]},
    %{category: "history", question: "The Great Wall of China was primarily built to protect against whom?", answer: "mongols", options: ["Japanese", "Mongols", "Russians", "Koreans"]},
    %{category: "history", question: "What ancient wonder was located in Alexandria?", answer: "lighthouse", options: ["Colossus", "Lighthouse", "Library", "Pyramid"]},
    %{category: "history", question: "Who painted the Mona Lisa?", answer: "leonardo da vinci", options: ["Michelangelo", "Raphael", "Leonardo da Vinci", "Donatello"]},

    # Geography
    %{category: "geography", question: "What is the largest country by land area?", answer: "russia", options: ["Canada", "China", "USA", "Russia"]},
    %{category: "geography", question: "What is the longest river in the world?", answer: "nile", options: ["Amazon", "Nile", "Mississippi", "Yangtze"]},
    %{category: "geography", question: "Which continent has the most countries?", answer: "africa", options: ["Asia", "Europe", "Africa", "South America"]},
    %{category: "geography", question: "What is the capital of Australia?", answer: "canberra", options: ["Sydney", "Melbourne", "Canberra", "Perth"]},
    %{category: "geography", question: "Mount Everest is located in which mountain range?", answer: "himalayas", options: ["Alps", "Andes", "Himalayas", "Rockies"]},

    # Entertainment
    %{category: "entertainment", question: "What is the highest-grossing film of all time?", answer: "avatar", options: ["Titanic", "Avatar", "Avengers: Endgame", "Star Wars"]},
    %{category: "entertainment", question: "Who wrote the Harry Potter series?", answer: "j.k. rowling", options: ["Stephen King", "J.K. Rowling", "George R.R. Martin", "J.R.R. Tolkien"]},
    %{category: "entertainment", question: "What band was Freddie Mercury the lead singer of?", answer: "queen", options: ["The Beatles", "Led Zeppelin", "Queen", "Pink Floyd"]},
    %{category: "entertainment", question: "What year was the first Star Wars movie released?", answer: "1977", options: ["1975", "1977", "1979", "1981"]},
    %{category: "entertainment", question: "What is the name of Batman's butler?", answer: "alfred", options: ["James", "Alfred", "Bruce", "Gordon"]}
  ]

  @categories ["science", "technology", "history", "geography", "entertainment"]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a random question, optionally from a specific category.
  """
  def get_question(category \\ nil) do
    GenServer.call(__MODULE__, {:get_question, category})
  end

  @doc """
  Checks an answer and updates score.
  """
  def check_answer(session_id, question_id, answer) do
    GenServer.call(__MODULE__, {:check_answer, session_id, question_id, answer})
  end

  @doc """
  Gets current session score.
  """
  def get_score(session_id) do
    GenServer.call(__MODULE__, {:get_score, session_id})
  end

  @doc """
  Resets session score.
  """
  def reset_score(session_id) do
    GenServer.call(__MODULE__, {:reset_score, session_id})
  end

  @doc """
  Gets leaderboard.
  """
  def leaderboard(limit \\ 10) do
    GenServer.call(__MODULE__, {:leaderboard, limit})
  end

  @doc """
  Saves a high score with nickname.
  """
  def save_score(session_id, nickname) do
    GenServer.call(__MODULE__, {:save_score, session_id, nickname})
  end

  @doc """
  Gets list of categories.
  """
  def categories do
    @categories
  end

  @doc """
  Gets stats.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "trivia_scores.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # ETS for active sessions
    :ets.new(:trivia_sessions, [:named_table, :public, :set])

    # Schedule session cleanup
    schedule_cleanup()

    Logger.info("[Trivia] Started with #{length(@questions)} questions")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get_question, category}, _from, state) do
    questions = if category && category in @categories do
      Enum.filter(@questions, & &1.category == category)
    else
      @questions
    end

    if Enum.empty?(questions) do
      {:reply, {:error, :no_questions}, state}
    else
      question = Enum.random(questions)
      question_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

      # Store question for answer verification (with TTL)
      :ets.insert(:trivia_sessions, {{:question, question_id}, question, System.system_time(:millisecond)})

      # Shuffle options
      shuffled_options = Enum.shuffle(question.options)

      result = %{
        id: question_id,
        category: question.category,
        question: question.question,
        options: shuffled_options
      }

      {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_call({:check_answer, session_id, question_id, answer}, _from, state) do
    case :ets.lookup(:trivia_sessions, {:question, question_id}) do
      [{{:question, ^question_id}, question, _ts}] ->
        # Clean up the question
        :ets.delete(:trivia_sessions, {:question, question_id})

        # Check answer (case-insensitive, trimmed)
        given = answer |> String.trim() |> String.downcase()
        correct = question.answer |> String.downcase()

        # Also check if the option text matches
        correct_option = Enum.find(question.options, fn opt ->
          String.downcase(opt) == given or
          String.downcase(String.first(opt)) == given or
          String.downcase(opt) == correct
        end)

        is_correct = given == correct or
                     (correct_option && String.downcase(correct_option) == correct)

        # Update session score
        update_session_score(session_id, is_correct)

        {:reply, {:ok, %{
          correct: is_correct,
          correct_answer: Enum.find(question.options, fn opt ->
            String.downcase(opt) |> String.contains?(correct)
          end) || question.answer
        }}, state}

      [] ->
        {:reply, {:error, :question_not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_score, session_id}, _from, state) do
    case :ets.lookup(:trivia_sessions, {:score, session_id}) do
      [{{:score, ^session_id}, score, _ts}] ->
        {:reply, score, state}
      [] ->
        {:reply, %{correct: 0, total: 0}, state}
    end
  end

  @impl true
  def handle_call({:reset_score, session_id}, _from, state) do
    :ets.delete(:trivia_sessions, {:score, session_id})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:leaderboard, limit}, _from, state) do
    scores = :dets.foldl(fn {_key, entry}, acc ->
      [entry | acc]
    end, [], @table_name)

    top = scores
      |> Enum.sort_by(& &1.correct, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, top}, state}
  end

  @impl true
  def handle_call({:save_score, session_id, nickname}, _from, state) do
    nickname = nickname
      |> String.trim()
      |> String.slice(0, 20)
      |> String.replace(~r/[^\w\s-]/, "")

    if nickname == "" do
      {:reply, {:error, :invalid_nickname}, state}
    else
      case :ets.lookup(:trivia_sessions, {:score, session_id}) do
        [{{:score, ^session_id}, score, _ts}] when score.total > 0 ->
          entry = %{
            nickname: nickname,
            correct: score.correct,
            total: score.total,
            percentage: round(score.correct / score.total * 100),
            saved_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }

          key = {nickname, System.system_time(:millisecond)}
          :dets.insert(@table_name, {key, entry})
          :dets.sync(@table_name)

          # Reset session score after saving
          :ets.delete(:trivia_sessions, {:score, session_id})

          Logger.info("[Trivia] Score saved: #{nickname} - #{score.correct}/#{score.total}")
          {:reply, {:ok, entry}, state}

        _ ->
          {:reply, {:error, :no_score}, state}
      end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total_scores = :dets.foldl(fn _, acc -> acc + 1 end, 0, @table_name)

    {:reply, %{
      total_questions: length(@questions),
      total_categories: length(@categories),
      total_saved_scores: total_scores
    }, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp update_session_score(session_id, is_correct) do
    now = System.system_time(:millisecond)

    score = case :ets.lookup(:trivia_sessions, {:score, session_id}) do
      [{{:score, ^session_id}, s, _ts}] -> s
      [] -> %{correct: 0, total: 0}
    end

    new_score = %{
      correct: score.correct + (if is_correct, do: 1, else: 0),
      total: score.total + 1
    }

    :ets.insert(:trivia_sessions, {{:score, session_id}, new_score, now})
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 300_000)  # Every 5 minutes
  end

  defp cleanup_expired_sessions do
    cutoff = System.system_time(:millisecond) - @session_ttl_ms

    expired = :ets.foldl(fn
      {key, _data, ts}, acc when ts < cutoff -> [key | acc]
      _, acc -> acc
    end, [], :trivia_sessions)

    Enum.each(expired, fn key ->
      :ets.delete(:trivia_sessions, key)
    end)
  end
end
