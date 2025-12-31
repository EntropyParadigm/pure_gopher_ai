defmodule PureGopherAi.Fortune do
  @moduledoc """
  Fortune/Quote service providing random quotes, wisdom, and fortunes.

  Features:
  - Random quotes from curated collection
  - Multiple categories (wisdom, programming, funny, philosophy, motivation)
  - Quote of the day (consistent per day)
  - Fortune cookie style output
  - AI-enhanced fortune interpretation
  - Custom quote submission
  """

  use GenServer
  require Logger

  alias PureGopherAi.AiEngine

  @categories %{
    "wisdom" => %{
      name: "Ancient Wisdom",
      description: "Timeless wisdom from philosophers and sages",
      quotes: [
        {"The only true wisdom is in knowing you know nothing.", "Socrates"},
        {"The journey of a thousand miles begins with one step.", "Lao Tzu"},
        {"Know thyself.", "Oracle at Delphi"},
        {"The unexamined life is not worth living.", "Socrates"},
        {"To be yourself in a world that is constantly trying to make you something else is the greatest accomplishment.", "Ralph Waldo Emerson"},
        {"In the middle of difficulty lies opportunity.", "Albert Einstein"},
        {"He who has a why to live can bear almost any how.", "Friedrich Nietzsche"},
        {"The only thing I know is that I know nothing.", "Socrates"},
        {"Everything in moderation, including moderation.", "Oscar Wilde"},
        {"The wise man does at once what the fool does finally.", "Niccolo Machiavelli"}
      ]
    },
    "programming" => %{
      name: "Programming Wisdom",
      description: "Insights from the world of software development",
      quotes: [
        {"Programs must be written for people to read, and only incidentally for machines to execute.", "Harold Abelson"},
        {"Any fool can write code that a computer can understand. Good programmers write code that humans can understand.", "Martin Fowler"},
        {"First, solve the problem. Then, write the code.", "John Johnson"},
        {"The best way to predict the future is to implement it.", "David Heinemeier Hansson"},
        {"Simplicity is the soul of efficiency.", "Austin Freeman"},
        {"Code is like humor. When you have to explain it, it's bad.", "Cory House"},
        {"Make it work, make it right, make it fast.", "Kent Beck"},
        {"The most dangerous phrase in the language is 'We've always done it this way.'", "Grace Hopper"},
        {"It's not a bug – it's an undocumented feature.", "Anonymous"},
        {"There are only two hard things in Computer Science: cache invalidation and naming things.", "Phil Karlton"},
        {"Talk is cheap. Show me the code.", "Linus Torvalds"},
        {"Debugging is twice as hard as writing the code in the first place.", "Brian Kernighan"},
        {"The best error message is the one that never shows up.", "Thomas Fuchs"},
        {"Measuring programming progress by lines of code is like measuring aircraft building progress by weight.", "Bill Gates"},
        {"Sometimes it pays to stay in bed on Monday, rather than spending the rest of the week debugging Monday's code.", "Dan Salomon"}
      ]
    },
    "funny" => %{
      name: "Humorous Quotes",
      description: "Wit and humor to brighten your day",
      quotes: [
        {"I'm not superstitious, but I am a little stitious.", "Michael Scott"},
        {"I used to think I was indecisive, but now I'm not so sure.", "Anonymous"},
        {"I'm on a seafood diet. I see food and I eat it.", "Anonymous"},
        {"I told my wife she was drawing her eyebrows too high. She looked surprised.", "Anonymous"},
        {"I'm not lazy, I'm just on energy-saving mode.", "Anonymous"},
        {"The only mystery in life is why the kamikaze pilots wore helmets.", "Al McGuire"},
        {"I don't need a hair stylist, my pillow gives me a new hairstyle every morning.", "Anonymous"},
        {"My bed is a magical place where I suddenly remember everything I forgot to do.", "Anonymous"},
        {"Common sense is like deodorant. The people who need it most never use it.", "Anonymous"},
        {"Light travels faster than sound. This is why some people appear bright until they speak.", "Steven Wright"}
      ]
    },
    "philosophy" => %{
      name: "Philosophical Thoughts",
      description: "Deep reflections on existence and meaning",
      quotes: [
        {"I think, therefore I am.", "Rene Descartes"},
        {"The only thing we have to fear is fear itself.", "Franklin D. Roosevelt"},
        {"To be is to do.", "Socrates"},
        {"To do is to be.", "Jean-Paul Sartre"},
        {"Do be do be do.", "Frank Sinatra"},
        {"Man is condemned to be free.", "Jean-Paul Sartre"},
        {"One cannot step twice in the same river.", "Heraclitus"},
        {"The unexamined life is not worth living.", "Socrates"},
        {"Happiness is not an ideal of reason, but of imagination.", "Immanuel Kant"},
        {"We are what we repeatedly do. Excellence, then, is not an act, but a habit.", "Aristotle"},
        {"The life of man is solitary, poor, nasty, brutish, and short.", "Thomas Hobbes"},
        {"God is dead. God remains dead. And we have killed him.", "Friedrich Nietzsche"},
        {"I can control my passions and emotions if I can understand their nature.", "Spinoza"},
        {"The mind is everything. What you think you become.", "Buddha"}
      ]
    },
    "motivation" => %{
      name: "Motivational Quotes",
      description: "Inspiration to push forward",
      quotes: [
        {"The only way to do great work is to love what you do.", "Steve Jobs"},
        {"Believe you can and you're halfway there.", "Theodore Roosevelt"},
        {"Success is not final, failure is not fatal: it is the courage to continue that counts.", "Winston Churchill"},
        {"It does not matter how slowly you go as long as you do not stop.", "Confucius"},
        {"The future belongs to those who believe in the beauty of their dreams.", "Eleanor Roosevelt"},
        {"You miss 100% of the shots you don't take.", "Wayne Gretzky"},
        {"Whether you think you can or you think you can't, you're right.", "Henry Ford"},
        {"The best time to plant a tree was 20 years ago. The second best time is now.", "Chinese Proverb"},
        {"Don't watch the clock; do what it does. Keep going.", "Sam Levenson"},
        {"Everything you've ever wanted is on the other side of fear.", "George Addair"},
        {"Hardships often prepare ordinary people for an extraordinary destiny.", "C.S. Lewis"},
        {"The only limit to our realization of tomorrow is our doubts of today.", "Franklin D. Roosevelt"}
      ]
    },
    "unix" => %{
      name: "Unix Fortune",
      description: "Classic fortune file style quotes",
      quotes: [
        {"You will be attacked by a duck.", "fortune(6)"},
        {"Today is a good day to bstrstrdsay lumpfh!!", "fortune(6)"},
        {"Your lucky number is 3552664958674928.", "fortune(6)"},
        {"You will be successful in love.", "fortune(6)"},
        {"Beware of low-flying butterflies.", "fortune(6)"},
        {"A conclusion is simply the place where you got tired of thinking.", "fortune(6)"},
        {"All generalizations are false, including this one.", "fortune(6)"},
        {"A penny saved is a government oversight.", "fortune(6)"},
        {"You're not drunk if you can lie on the floor without holding on.", "fortune(6)"},
        {"Chocolate makes it all better.", "fortune(6)"},
        {"Today you will receive a fortune cookie.", "fortune(6)"},
        {"Help! I'm trapped in a fortune cookie factory!", "fortune(6)"},
        {"Ignore previous fortune.", "fortune(6)"}
      ]
    }
  }

  @fortune_cookies [
    "A beautiful, smart, and loving person will be coming into your life.",
    "A dubious friend may be an enemy in camouflage.",
    "A faithful friend is a strong defense.",
    "A fresh start will put you on your way.",
    "A golden egg of opportunity falls into your lap this month.",
    "A good time to finish up old tasks.",
    "A hunch is creativity trying to tell you something.",
    "A lifetime of happiness lies ahead of you.",
    "A light heart carries you through all the hard times.",
    "A new perspective will come with the new year.",
    "Accept something that you cannot change, and you will feel better.",
    "Adventure can be real happiness.",
    "All the effort you are making will ultimately pay off.",
    "An important person will offer you support.",
    "Be patient and you will be rewarded.",
    "Better to have loved and lost than to never have loved at all.",
    "Curiosity kills boredom. Nothing can kill curiosity.",
    "Do not make extra work for yourself.",
    "Don't just spend time. Invest it.",
    "Every flower blooms in its own time."
  ]

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Get a random fortune from any category.
  """
  def random do
    GenServer.call(__MODULE__, :random)
  end

  @doc """
  Get a random fortune from a specific category.
  """
  def random(category) when is_binary(category) do
    GenServer.call(__MODULE__, {:random, category})
  end

  @doc """
  Get the fortune of the day (consistent per day).
  """
  def fortune_of_the_day do
    GenServer.call(__MODULE__, :fortune_of_the_day)
  end

  @doc """
  Get a fortune cookie message.
  """
  def fortune_cookie do
    GenServer.call(__MODULE__, :fortune_cookie)
  end

  @doc """
  List all categories.
  """
  def list_categories do
    GenServer.call(__MODULE__, :list_categories)
  end

  @doc """
  Get all quotes from a category.
  """
  def get_category(category) do
    GenServer.call(__MODULE__, {:get_category, category})
  end

  @doc """
  Get AI interpretation of a fortune.
  """
  def interpret(fortune) do
    GenServer.call(__MODULE__, {:interpret, fortune}, 60_000)
  end

  @doc """
  Add a custom quote (stored in memory only).
  """
  def add_quote(category, quote, author) do
    GenServer.call(__MODULE__, {:add_quote, category, quote, author})
  end

  @doc """
  Search quotes by keyword.
  """
  def search(keyword) do
    GenServer.call(__MODULE__, {:search, keyword})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Copy default categories and allow custom additions
    {:ok, %{categories: @categories, custom_quotes: %{}}}
  end

  @impl true
  def handle_call(:random, _from, state) do
    all_quotes = get_all_quotes(state)
    fortune = Enum.random(all_quotes)
    {:reply, {:ok, fortune}, state}
  end

  @impl true
  def handle_call({:random, category}, _from, state) do
    case Map.get(state.categories, category) do
      %{quotes: quotes} when quotes != [] ->
        {quote, author} = Enum.random(quotes)
        {:reply, {:ok, {quote, author, category}}, state}

      _ ->
        # Check custom quotes
        case Map.get(state.custom_quotes, category) do
          quotes when is_list(quotes) and quotes != [] ->
            {quote, author} = Enum.random(quotes)
            {:reply, {:ok, {quote, author, category}}, state}

          _ ->
            {:reply, {:error, :category_not_found}, state}
        end
    end
  end

  @impl true
  def handle_call(:fortune_of_the_day, _from, state) do
    # Use date as seed for consistent daily fortune
    {year, month, day} = Date.utc_today() |> Date.to_erl()
    seed = year * 10000 + month * 100 + day
    :rand.seed(:exsss, {seed, seed, seed})

    all_quotes = get_all_quotes(state)
    fortune = Enum.at(all_quotes, rem(seed, length(all_quotes)))

    # Reset random seed
    :rand.seed(:exsss)

    {:reply, {:ok, fortune}, state}
  end

  @impl true
  def handle_call(:fortune_cookie, _from, state) do
    cookie = Enum.random(@fortune_cookies)
    lucky_numbers = Enum.take_random(1..49, 6) |> Enum.sort() |> Enum.join(" ")
    {:reply, {:ok, {cookie, lucky_numbers}}, state}
  end

  @impl true
  def handle_call(:list_categories, _from, state) do
    categories =
      state.categories
      |> Enum.map(fn {id, %{name: name, description: desc, quotes: quotes}} ->
        %{id: id, name: name, description: desc, count: length(quotes)}
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, {:ok, categories}, state}
  end

  @impl true
  def handle_call({:get_category, category}, _from, state) do
    case Map.get(state.categories, category) do
      %{name: name, description: desc, quotes: quotes} ->
        {:reply, {:ok, %{name: name, description: desc, quotes: quotes}}, state}

      nil ->
        {:reply, {:error, :category_not_found}, state}
    end
  end

  @impl true
  def handle_call({:interpret, fortune}, _from, state) do
    {quote_text, author} =
      case fortune do
        {q, a, _cat} -> {q, a}
        {q, a} -> {q, a}
      end

    prompt = """
    Interpret this quote as if you were a wise fortune teller or oracle.
    Give a brief, mystical interpretation of what this might mean for
    the person reading it today. Be insightful but concise (2-3 sentences).

    Quote: "#{quote_text}" - #{author}

    Interpretation:
    """

    case AiEngine.generate(prompt, max_new_tokens: 150) do
      {:ok, interpretation} ->
        {:reply, {:ok, String.trim(interpretation)}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:add_quote, category, quote, author}, _from, state) do
    custom = Map.get(state.custom_quotes, category, [])
    updated = [{quote, author} | custom]
    new_state = %{state | custom_quotes: Map.put(state.custom_quotes, category, updated)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:search, keyword}, _from, state) do
    keyword_lower = String.downcase(keyword)

    results =
      get_all_quotes(state)
      |> Enum.filter(fn {quote, author, _cat} ->
        String.contains?(String.downcase(quote), keyword_lower) or
          String.contains?(String.downcase(author), keyword_lower)
      end)

    {:reply, {:ok, results}, state}
  end

  # Helper functions

  defp get_all_quotes(state) do
    builtin =
      state.categories
      |> Enum.flat_map(fn {cat, %{quotes: quotes}} ->
        Enum.map(quotes, fn {q, a} -> {q, a, cat} end)
      end)

    custom =
      state.custom_quotes
      |> Enum.flat_map(fn {cat, quotes} ->
        Enum.map(quotes, fn {q, a} -> {q, a, cat} end)
      end)

    builtin ++ custom
  end

  # Format helpers for handlers

  @doc """
  Format a fortune as ASCII art fortune cookie style.
  """
  def format_cookie_style({quote, author, _category}) do
    format_cookie_style({quote, author})
  end

  def format_cookie_style({quote, author}) do
    """
        _______
       /       \\
      |  ~  ~  |
      |   __   |
       \\_/  \\_/

    #{wrap_text(quote, 50)}

        - #{author}

     Lucky numbers: #{Enum.take_random(1..49, 6) |> Enum.sort() |> Enum.join(" ")}
    """
  end

  @doc """
  Format a fortune cookie message with numbers.
  """
  def format_fortune_cookie({message, numbers}) do
    """
        _______
       /       \\
      |  ~  ~  |
      |   __   |
       \\_/  \\_/

    #{wrap_text(message, 50)}

     Lucky numbers: #{numbers}
    """
  end

  defp wrap_text(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce({"", 0}, fn word, {acc, line_len} ->
      word_len = String.length(word)

      if line_len + word_len + 1 > width do
        {acc <> "\n    " <> word, word_len}
      else
        separator = if acc == "", do: "    ", else: " "
        {acc <> separator <> word, line_len + word_len + 1}
      end
    end)
    |> elem(0)
  end
end
