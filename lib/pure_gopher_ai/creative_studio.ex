defmodule PureGopherAi.CreativeStudio do
  @moduledoc """
  AI-powered creative writing studio for generating stories, poems, and lyrics.

  Features:
  - Short story generation from prompts
  - Poetry: haiku, sonnet, free verse, limerick
  - Song lyrics from themes/moods
  - Story continuation
  - Style rewriting (noir, fantasy, sci-fi, romance)
  """

  alias PureGopherAi.AiEngine

  @genres [:noir, :fantasy, :scifi, :romance, :horror, :mystery, :comedy, :drama]
  @poem_types [:haiku, :sonnet, :limerick, :free_verse, :acrostic, :ballad]
  @moods [:happy, :sad, :angry, :peaceful, :mysterious, :romantic, :energetic, :melancholic]
  @max_story_context 2000

  @doc """
  Returns available story genres.
  """
  @spec genres() :: list(atom())
  def genres, do: @genres

  @doc """
  Returns available poem types.
  """
  @spec poem_types() :: list(atom())
  def poem_types, do: @poem_types

  @doc """
  Returns available moods for lyrics.
  """
  @spec moods() :: list(atom())
  def moods, do: @moods

  @doc """
  Generate a short story from a prompt.
  """
  @spec story(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def story(prompt, opts \\ []) do
    genre = Keyword.get(opts, :genre, :general)
    length = Keyword.get(opts, :length, :short)

    length_instruction = case length do
      :flash -> "Write a flash fiction piece (under 500 words)."
      :short -> "Write a short story (500-1000 words)."
      :medium -> "Write a medium-length story (1000-2000 words)."
      _ -> "Write a short story."
    end

    genre_instruction = if genre != :general do
      "Write in the #{genre} genre style."
    else
      ""
    end

    ai_prompt = """
    You are a creative fiction writer. Write a compelling story based on this prompt:

    Prompt: #{prompt}

    #{genre_instruction}
    #{length_instruction}

    Include vivid descriptions, engaging dialogue, and a satisfying narrative arc.
    Write the story directly without any preamble.
    """

    case AiEngine.generate_safe(ai_prompt, max_new_tokens: 1200) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Generate poetry of various types.
  """
  @spec poem(String.t(), atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def poem(topic, type \\ :free_verse, opts \\ []) when type in @poem_types do
    mood = Keyword.get(opts, :mood, nil)

    type_instruction = case type do
      :haiku ->
        "Write a haiku (5-7-5 syllable pattern, 3 lines)."

      :sonnet ->
        "Write a Shakespearean sonnet (14 lines, ABAB CDCD EFEF GG rhyme scheme, iambic pentameter)."

      :limerick ->
        "Write a limerick (5 lines, AABBA rhyme scheme, humorous)."

      :free_verse ->
        "Write a free verse poem (no strict meter or rhyme, focus on imagery and emotion)."

      :acrostic ->
        "Write an acrostic poem where the first letters of each line spell out '#{topic}'."

      :ballad ->
        "Write a narrative ballad with a rhythmic pattern and refrain."
    end

    mood_instruction = if mood do
      "The poem should evoke a #{mood} mood."
    else
      ""
    end

    ai_prompt = """
    You are a poet. Write a poem about:

    Topic: #{topic}

    #{type_instruction}
    #{mood_instruction}

    Write only the poem, no explanations.
    """

    case AiEngine.generate_safe(ai_prompt, max_new_tokens: 400) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Generate song lyrics.
  """
  @spec lyrics(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def lyrics(theme, opts \\ []) do
    mood = Keyword.get(opts, :mood, :general)
    style = Keyword.get(opts, :style, :pop)

    style_instruction = case style do
      :pop -> "Write in a pop music style with catchy hooks."
      :rock -> "Write in a rock style with powerful imagery."
      :folk -> "Write in a folk style with storytelling elements."
      :country -> "Write in a country music style."
      :blues -> "Write in a blues style with emotional depth."
      :rap -> "Write rap lyrics with rhythm and wordplay."
      _ -> "Write song lyrics."
    end

    mood_instruction = if mood != :general do
      "The song should have a #{mood} mood."
    else
      ""
    end

    ai_prompt = """
    You are a songwriter. Write song lyrics about:

    Theme: #{theme}

    #{style_instruction}
    #{mood_instruction}

    Include verses, a chorus, and optionally a bridge.
    Format with clear section labels (Verse 1, Chorus, etc.).
    Write only the lyrics.
    """

    case AiEngine.generate_safe(ai_prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Continue a story from where it left off.
  """
  @spec continue_story(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def continue_story(story_so_far, opts \\ []) do
    direction = Keyword.get(opts, :direction, nil)
    length = Keyword.get(opts, :length, :medium)

    direction_instruction = if direction do
      "Take the story in this direction: #{direction}"
    else
      "Continue the story naturally based on what has happened."
    end

    length_instruction = case length do
      :short -> "Add about 200-300 words."
      :medium -> "Add about 400-600 words."
      :long -> "Add about 800-1000 words."
      _ -> "Add a reasonable continuation."
    end

    ai_prompt = """
    You are a fiction writer. Continue this story:

    Story so far:
    ---
    #{String.slice(story_so_far, -@max_story_context, @max_story_context)}
    ---

    #{direction_instruction}
    #{length_instruction}

    Maintain the same style, tone, and voice.
    Write only the continuation, starting right where the story left off.
    """

    case AiEngine.generate_safe(ai_prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Rewrite content in a different genre/style.
  """
  @spec rewrite(String.t(), atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def rewrite(content, target_style, _opts \\ []) when target_style in @genres do
    style_description = case target_style do
      :noir -> "dark, cynical film noir with hard-boiled narration"
      :fantasy -> "high fantasy with magic, epic language, and mythical elements"
      :scifi -> "science fiction with futuristic technology and scientific concepts"
      :romance -> "romantic fiction with emotional depth and relationship focus"
      :horror -> "horror with suspense, dread, and dark atmosphere"
      :mystery -> "mystery with clues, suspense, and detective elements"
      :comedy -> "comedy with humor, wit, and amusing situations"
      :drama -> "dramatic fiction with emotional intensity and character depth"
    end

    ai_prompt = """
    You are a creative writer. Rewrite the following content in the style of #{style_description}:

    Original:
    ---
    #{content}
    ---

    Keep the core story/meaning but transform it to fit the #{target_style} genre.
    Write only the rewritten version.
    """

    case AiEngine.generate_safe(ai_prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Generate writing prompts for inspiration.
  """
  @spec generate_prompts(atom(), pos_integer()) :: {:ok, list(String.t())} | {:error, term()}
  def generate_prompts(category \\ :general, count \\ 5) do
    category_instruction = case category do
      :fantasy -> "fantasy and magic themed"
      :scifi -> "science fiction themed"
      :romance -> "romance and relationships themed"
      :horror -> "horror and supernatural themed"
      :mystery -> "mystery and detective themed"
      :slice_of_life -> "slice of life and everyday moments themed"
      _ -> "varied and interesting"
    end

    ai_prompt = """
    Generate #{count} creative writing prompts that are #{category_instruction}.

    Each prompt should:
    - Be 1-2 sentences
    - Spark imagination
    - Provide a unique scenario or starting point

    List each prompt on its own line, numbered 1-#{count}.
    """

    case AiEngine.generate_safe(ai_prompt, max_new_tokens: 300) do
      {:ok, result} ->
        prompts = result
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&clean_prompt_line/1)
        |> Enum.take(count)

        {:ok, prompts}

      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Generate a character profile.
  """
  @spec character(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def character(traits, opts \\ []) do
    genre = Keyword.get(opts, :genre, :general)
    role = Keyword.get(opts, :role, nil)

    role_instruction = if role do
      "This character is a #{role}."
    else
      ""
    end

    genre_instruction = if genre != :general do
      "The character should fit in a #{genre} setting."
    else
      ""
    end

    ai_prompt = """
    Create a detailed character profile with these traits:

    Traits: #{traits}
    #{role_instruction}
    #{genre_instruction}

    Include:
    - Name and basic description
    - Personality traits
    - Background/history
    - Motivations and goals
    - Strengths and weaknesses
    - A memorable quirk or habit
    """

    case AiEngine.generate_safe(ai_prompt, max_new_tokens: 500) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  @doc """
  Generate a world/setting description.
  """
  @spec worldbuild(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def worldbuild(concept, opts \\ []) do
    genre = Keyword.get(opts, :genre, :fantasy)
    focus = Keyword.get(opts, :focus, nil)

    focus_instruction = if focus do
      "Focus especially on: #{focus}"
    else
      ""
    end

    ai_prompt = """
    Create a detailed world/setting based on this concept:

    Concept: #{concept}
    Genre: #{genre}
    #{focus_instruction}

    Include:
    - Geography and environment
    - Culture and society
    - History and lore
    - Unique elements that make this world special
    - Potential conflicts or tensions

    Write the description in an engaging, narrative style.
    """

    case AiEngine.generate_safe(ai_prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      {:error, :blocked, reason} -> {:error, {:blocked, reason}}
      error -> error
    end
  end

  # Private helpers

  defp clean_prompt_line(line) do
    line
    |> String.replace(~r/^\d+[\.\)]\s*/, "")
    |> String.replace(~r/^[-•]\s*/, "")
    |> String.trim()
  end
end
