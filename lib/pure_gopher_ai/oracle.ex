defmodule PureGopherAi.Oracle do
  @moduledoc """
  AI-powered oracle and advisor for fun daily content with AI personality.

  Features:
  - Daily wisdom/fortune
  - Situational advice
  - Tarot card readings with AI interpretation
  - I Ching consultation
  - Dream interpretation
  - Personality-based horoscopes
  """

  alias PureGopherAi.AiEngine

  @zodiac_signs [:aries, :taurus, :gemini, :cancer, :leo, :virgo,
                 :libra, :scorpio, :sagittarius, :capricorn, :aquarius, :pisces]

  @tarot_major_arcana [
    {"The Fool", "new beginnings, innocence, spontaneity"},
    {"The Magician", "manifestation, resourcefulness, power"},
    {"The High Priestess", "intuition, sacred knowledge, mystery"},
    {"The Empress", "femininity, beauty, nature, abundance"},
    {"The Emperor", "authority, structure, control, fatherhood"},
    {"The Hierophant", "spiritual wisdom, tradition, conformity"},
    {"The Lovers", "love, harmony, relationships, choices"},
    {"The Chariot", "control, willpower, success, determination"},
    {"Strength", "courage, patience, control, compassion"},
    {"The Hermit", "soul searching, introspection, inner guidance"},
    {"Wheel of Fortune", "change, cycles, fate, destiny"},
    {"Justice", "fairness, truth, law, cause and effect"},
    {"The Hanged Man", "pause, surrender, new perspective"},
    {"Death", "endings, change, transformation, transition"},
    {"Temperance", "balance, moderation, patience, purpose"},
    {"The Devil", "shadow self, attachment, addiction, restriction"},
    {"The Tower", "sudden change, upheaval, revelation"},
    {"The Star", "hope, faith, purpose, renewal, spirituality"},
    {"The Moon", "illusion, fear, anxiety, subconscious"},
    {"The Sun", "positivity, fun, warmth, success, vitality"},
    {"Judgement", "reflection, reckoning, awakening"},
    {"The World", "completion, integration, accomplishment"}
  ]

  @i_ching_trigrams [
    {"Heaven", "☰", "creative, strong, initiating"},
    {"Earth", "☷", "receptive, yielding, nurturing"},
    {"Thunder", "☳", "arousing, shocking, initiative"},
    {"Water", "☵", "abysmal, dangerous, flowing"},
    {"Mountain", "☶", "keeping still, meditation, stopping"},
    {"Wind", "☴", "gentle, penetrating, following"},
    {"Fire", "☲", "clinging, bright, awareness"},
    {"Lake", "☱", "joyous, pleasure, satisfaction"}
  ]

  @doc """
  Returns zodiac signs.
  """
  @spec zodiac_signs() :: list(atom())
  def zodiac_signs, do: @zodiac_signs

  @doc """
  Generate daily fortune/wisdom.
  """
  @spec daily_fortune(keyword()) :: {:ok, String.t()} | {:error, term()}
  def daily_fortune(opts \\ []) do
    theme = Keyword.get(opts, :theme, :general)

    theme_instruction = case theme do
      :love -> "Focus on matters of love and relationships."
      :career -> "Focus on career and professional matters."
      :health -> "Focus on health and well-being."
      :money -> "Focus on financial matters."
      :spiritual -> "Focus on spiritual growth and inner wisdom."
      :general -> "Cover various aspects of life."
      _ -> "Cover various aspects of life."
    end

    prompt = """
    You are a wise oracle. Generate a daily fortune or piece of wisdom.

    #{theme_instruction}

    The fortune should be:
    - Thoughtful and meaningful (not generic)
    - Poetic but clear
    - Encouraging and insightful
    - About 2-4 sentences

    Write only the fortune, in an oracular style.
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 150) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Give situational advice.
  """
  @spec advice(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def advice(situation, opts \\ []) do
    tone = Keyword.get(opts, :tone, :wise)

    tone_instruction = case tone do
      :wise -> "Speak as a wise elder with life experience."
      :practical -> "Give practical, actionable advice."
      :philosophical -> "Take a philosophical approach."
      :compassionate -> "Be warm and compassionate."
      :direct -> "Be direct and to the point."
      _ -> "Speak as a wise advisor."
    end

    prompt = """
    You are a wise advisor. Someone comes to you with this situation:

    "#{situation}"

    #{tone_instruction}

    Give thoughtful advice that:
    - Acknowledges their feelings
    - Offers a helpful perspective
    - Suggests a path forward
    - Is neither preachy nor dismissive

    Keep it concise but meaningful (3-5 sentences).
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 300) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Perform a tarot reading.
  """
  @spec tarot_reading(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def tarot_reading(question \\ nil, opts \\ []) do
    spread = Keyword.get(opts, :spread, :three_card)
    cards = draw_cards_for_spread(spread)
    spread_description = spread_name(spread)
    card_descriptions = describe_cards(cards, spread)
    question_text = format_question(question)

    prompt = """
    You are a wise tarot reader. Interpret this #{spread_description}:

    #{question_text}

    Cards drawn:
    #{card_descriptions}

    Give a thoughtful interpretation that:
    - Weaves the cards into a cohesive narrative
    - Addresses the question if one was asked
    - Offers insight without being deterministic
    - Maintains a mystical but accessible tone

    Write the interpretation (about 4-6 sentences).
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 400) do
      {:ok, interpretation} ->
        format_tarot_result(spread_description, cards, question, interpretation)

      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  # Returns position names for a spread type
  defp spread_positions(:three_card), do: ["Past", "Present", "Future"]
  defp spread_positions(:celtic_cross) do
    ["Present Situation", "Challenge", "Distant Past", "Recent Past",
     "Possible Future", "Immediate Future", "Self", "Environment",
     "Hopes/Fears", "Outcome"]
  end
  defp spread_positions(_), do: nil

  # Formats cards with positions and reversal status
  defp describe_cards(cards, spread) do
    positions = spread_positions(spread)

    cards
    |> Enum.with_index()
    |> Enum.map(fn {{name, meaning}, idx} ->
      reversed = :rand.uniform() > 0.7
      position = if positions, do: Enum.at(positions, idx), else: "Card #{idx + 1}"
      reversed_text = if reversed, do: " (Reversed)", else: ""
      "#{position}: #{name}#{reversed_text} - #{meaning}"
    end)
    |> Enum.join("\n")
  end

  # Builds the final result map
  defp format_tarot_result(spread_description, cards, question, interpretation) do
    {:ok, %{
      spread: spread_description,
      cards: cards,
      question: question,
      interpretation: String.trim(interpretation)
    }}
  end

  defp draw_cards_for_spread(:single), do: draw_tarot_cards(1)
  defp draw_cards_for_spread(:three_card), do: draw_tarot_cards(3)
  defp draw_cards_for_spread(:celtic_cross), do: draw_tarot_cards(10)
  defp draw_cards_for_spread(_), do: draw_tarot_cards(3)

  defp spread_name(:single), do: "Single Card Reading"
  defp spread_name(:three_card), do: "Past, Present, Future Spread"
  defp spread_name(:celtic_cross), do: "Celtic Cross Spread"
  defp spread_name(_), do: "Three Card Spread"

  defp format_question(nil), do: "This is a general reading with no specific question."
  defp format_question(question), do: "The querent asks: \"#{question}\""

  @doc """
  Consult the I Ching.
  """
  @spec i_ching(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def i_ching(question \\ nil) do
    # Generate two trigrams to form a hexagram
    [lower, upper] = Enum.take_random(@i_ching_trigrams, 2)
    {lower_name, lower_symbol, lower_meaning} = lower
    {upper_name, upper_symbol, upper_meaning} = upper

    hexagram_number = :rand.uniform(64)

    question_text = if question do
      "The question: \"#{question}\""
    else
      "A general consultation for guidance."
    end

    prompt = """
    You are an I Ching oracle. Interpret this casting:

    #{question_text}

    Hexagram #{hexagram_number}:
    Upper Trigram: #{upper_name} (#{upper_symbol}) - #{upper_meaning}
    Lower Trigram: #{lower_name} (#{lower_symbol}) - #{lower_meaning}

    Give a wise interpretation that:
    - Explains the interaction of the two trigrams
    - Relates it to the question or situation
    - Offers actionable wisdom
    - Maintains the contemplative I Ching style

    Write the interpretation (about 4-5 sentences).
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 350) do
      {:ok, interpretation} ->
        {:ok, %{
          hexagram: hexagram_number,
          upper: upper,
          lower: lower,
          question: question,
          interpretation: String.trim(interpretation)
        }}

      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Interpret a dream.
  """
  @spec dream_interpretation(String.t()) :: {:ok, String.t()} | {:error, term()}
  def dream_interpretation(dream) do
    prompt = """
    You are a dream interpreter with knowledge of symbolism and psychology.

    Interpret this dream:
    "#{dream}"

    Your interpretation should:
    - Identify key symbols and their meanings
    - Consider the emotional tone of the dream
    - Suggest what the dream might be processing
    - Offer insight without being too definitive

    Remember: Dreams are personal and complex. Offer perspective, not predictions.
    Write a thoughtful interpretation (about 4-6 sentences).
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 400) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Generate a horoscope.
  """
  @spec horoscope(atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def horoscope(sign, opts \\ []) when sign in @zodiac_signs do
    period = Keyword.get(opts, :period, :daily)
    focus = Keyword.get(opts, :focus, :general)

    period_instruction = case period do
      :daily -> "for today"
      :weekly -> "for this week"
      :monthly -> "for this month"
      _ -> "for today"
    end

    focus_instruction = case focus do
      :love -> "Focus on love and relationships."
      :career -> "Focus on career and work."
      :health -> "Focus on health and wellness."
      :general -> "Cover multiple life areas."
      _ -> "Cover multiple life areas."
    end

    sign_name = sign |> Atom.to_string() |> String.capitalize()

    prompt = """
    You are an astrologer. Write a horoscope #{period_instruction} for #{sign_name}.

    #{focus_instruction}

    The horoscope should:
    - Reference the qualities of #{sign_name}
    - Be encouraging but realistic
    - Offer specific guidance or themes
    - Be engaging and personal

    Write the horoscope (about 3-5 sentences). Address the reader as "you".
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 250) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Answer a yes/no question with oracular wisdom.
  """
  @spec yes_no_oracle(String.t()) :: {:ok, map()} | {:error, term()}
  def yes_no_oracle(question) do
    # Randomly determine the answer tendency
    tendency = Enum.random([:yes, :no, :maybe])

    prompt = """
    You are an ancient oracle answering a yes/no question.

    Question: "#{question}"
    Answer tendency: #{tendency}

    Respond in an oracular, mystical way that:
    - Leans #{tendency} but isn't absolute
    - Adds wisdom or a caveat
    - Is poetic and memorable
    - Is about 2-3 sentences

    Do not simply say "yes" or "no" - speak as an oracle would.
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 150) do
      {:ok, result} -> {:ok, %{tendency: tendency, response: String.trim(result)}}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Generate a daily affirmation.
  """
  @spec affirmation(atom()) :: {:ok, String.t()} | {:error, term()}
  def affirmation(theme \\ :general) do
    theme_instruction = case theme do
      :confidence -> "about self-confidence and self-worth"
      :peace -> "about inner peace and calm"
      :abundance -> "about abundance and prosperity"
      :love -> "about love and connection"
      :health -> "about health and vitality"
      :growth -> "about personal growth and learning"
      :general -> "covering any positive theme"
      _ -> "covering any positive theme"
    end

    prompt = """
    Generate a powerful daily affirmation #{theme_instruction}.

    The affirmation should:
    - Be in first person ("I am...", "I have...", "I embrace...")
    - Be positive and empowering
    - Feel authentic, not cheesy
    - Be memorable and repeatable

    Write only the affirmation (1-2 sentences).
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 80) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Provide life path guidance.
  """
  @spec life_path_reading(String.t()) :: {:ok, map()} | {:error, term()}
  def life_path_reading(birth_date) do
    # Calculate life path number (simplified numerology)
    life_path = calculate_life_path(birth_date)

    prompt = """
    You are a numerologist. Give a reading for Life Path Number #{life_path}.

    Describe:
    - The core traits of this life path
    - Strengths and challenges
    - Purpose and direction
    - Compatible paths

    Write a thoughtful reading (about 4-5 sentences).
    """

    case AiEngine.generate_safe(prompt, max_new_tokens: 300) do
      {:ok, result} -> {:ok, %{life_path: life_path, reading: String.trim(result)}}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  # Private helpers

  defp draw_tarot_cards(count) do
    Enum.take_random(@tarot_major_arcana, count)
  end

  defp calculate_life_path(date_string) do
    # Simple life path calculation
    digits = date_string
    |> String.replace(~r/[^\d]/, "")
    |> String.graphemes()
    |> Enum.map(&String.to_integer/1)

    reduce_to_single(Enum.sum(digits))
  end

  defp reduce_to_single(num) when num in [11, 22, 33], do: num  # Master numbers
  defp reduce_to_single(num) when num < 10, do: num
  defp reduce_to_single(num) do
    num
    |> Integer.digits()
    |> Enum.sum()
    |> reduce_to_single()
  end
end
