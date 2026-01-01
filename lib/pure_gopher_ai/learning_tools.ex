defmodule PureGopherAi.LearningTools do
  @moduledoc """
  AI-powered learning and educational tools.

  Features:
  - Flashcard generation from text
  - Quiz generation from content
  - ELI5 explanations
  - Enhanced dictionary definitions
  - Etymology and word history
  - Concept mapping
  """

  alias PureGopherAi.AiEngine

  @quiz_types [:multiple_choice, :true_false, :fill_blank, :short_answer]
  @age_levels [:child, :teen, :adult, :expert]

  @doc """
  Returns available quiz types.
  """
  def quiz_types, do: @quiz_types

  @doc """
  Returns available explanation levels.
  """
  def age_levels, do: @age_levels

  @doc """
  Generate flashcards from text content.
  """
  def flashcards(content, opts \\ []) do
    count = Keyword.get(opts, :count, 10)
    style = Keyword.get(opts, :style, :question_answer)

    style_instruction = case style do
      :question_answer -> "Each card should have a question on the front and answer on the back."
      :term_definition -> "Each card should have a term on the front and definition on the back."
      :concept_example -> "Each card should have a concept on the front and example on the back."
      _ -> "Each card should have a question on the front and answer on the back."
    end

    prompt = """
    You are an educational content creator. Generate #{count} flashcards from this content:

    Content:
    ---
    #{content}
    ---

    #{style_instruction}

    Format each flashcard as:
    FRONT: [front text]
    BACK: [back text]
    ---

    Create flashcards that cover the key concepts and facts.
    Make them clear and useful for studying.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} ->
        cards = parse_flashcards(result)
        {:ok, cards}

      error -> error
    end
  end

  @doc """
  Generate quiz questions from content.
  """
  def quiz(content, opts \\ []) do
    count = Keyword.get(opts, :count, 5)
    type = Keyword.get(opts, :type, :multiple_choice)

    type_instruction = case type do
      :multiple_choice ->
        """
        Create multiple choice questions with 4 options (A, B, C, D).
        Mark the correct answer with an asterisk (*).
        Format:
        Q: [question]
        A) [option]
        B) [option]
        *C) [correct option]
        D) [option]
        """

      :true_false ->
        """
        Create true/false questions.
        Format:
        Q: [statement]
        A: [True/False]
        """

      :fill_blank ->
        """
        Create fill-in-the-blank questions.
        Use _____ to indicate the blank.
        Format:
        Q: [sentence with _____]
        A: [answer]
        """

      :short_answer ->
        """
        Create short answer questions.
        Format:
        Q: [question]
        A: [expected answer]
        """

      _ ->
        "Create questions with answers."
    end

    prompt = """
    You are a quiz creator. Generate #{count} quiz questions from this content:

    Content:
    ---
    #{content}
    ---

    #{type_instruction}

    Create questions that test understanding of key concepts.
    Separate each question with ---
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} ->
        questions = parse_quiz(result, type)
        {:ok, questions}

      error -> error
    end
  end

  @doc """
  Explain a concept at a specific level (ELI5, etc).
  """
  def explain(concept, opts \\ []) do
    level = Keyword.get(opts, :level, :child)
    include_examples = Keyword.get(opts, :examples, true)

    level_instruction = case level do
      :child ->
        "Explain like I'm 5 years old. Use simple words, analogies, and everyday examples."
      :teen ->
        "Explain for a teenager. Use clear language and relatable examples."
      :adult ->
        "Explain for an adult with general knowledge. Be clear but don't oversimplify."
      :expert ->
        "Explain for an expert. Use proper terminology and cover nuances."
      _ ->
        "Explain clearly and simply."
    end

    examples_instruction = if include_examples do
      "Include 1-2 concrete examples to illustrate the concept."
    else
      ""
    end

    prompt = """
    #{level_instruction}

    Concept to explain: #{concept}

    #{examples_instruction}

    Write a clear, engaging explanation.
    """

    case AiEngine.generate(prompt, max_new_tokens: 500) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Get an enhanced dictionary definition.
  """
  def define(word, opts \\ []) do
    include_usage = Keyword.get(opts, :usage, true)
    include_synonyms = Keyword.get(opts, :synonyms, true)

    extras = []
    extras = if include_usage, do: ["- Example sentences showing usage" | extras], else: extras
    extras = if include_synonyms, do: ["- Synonyms and antonyms" | extras], else: extras
    extras_text = Enum.join(extras, "\n")

    prompt = """
    Define the word: "#{word}"

    Provide:
    - Part of speech
    - Clear definition(s)
    - Pronunciation guide (phonetic)
    #{extras_text}

    Be accurate and thorough.
    """

    case AiEngine.generate(prompt, max_new_tokens: 400) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Get the etymology (word origin and history).
  """
  def etymology(word) do
    prompt = """
    Explain the etymology of the word: "#{word}"

    Include:
    - Language of origin (Latin, Greek, Germanic, etc.)
    - Original meaning
    - How it evolved over time
    - Related words from the same root
    - When it entered English (if applicable)

    Be historically accurate and interesting.
    """

    case AiEngine.generate(prompt, max_new_tokens: 400) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Create a concept map from content.
  """
  def concept_map(topic, opts \\ []) do
    depth = Keyword.get(opts, :depth, 2)

    prompt = """
    Create a concept map for: #{topic}

    Create a hierarchical map with #{depth} levels of depth.

    Format:
    MAIN CONCEPT: [topic]
    ├── [subconcept 1]
    │   ├── [detail 1.1]
    │   └── [detail 1.2]
    ├── [subconcept 2]
    │   ├── [detail 2.1]
    │   └── [detail 2.2]
    └── [subconcept 3]
        ├── [detail 3.1]
        └── [detail 3.2]

    Use this visual format with proper tree characters.
    Include the most important concepts and relationships.
    """

    case AiEngine.generate(prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Summarize content for studying.
  """
  def study_summary(content, opts \\ []) do
    format = Keyword.get(opts, :format, :bullet_points)

    format_instruction = case format do
      :bullet_points -> "Use concise bullet points."
      :outline -> "Use an outline format with headers and subpoints."
      :paragraph -> "Write a concise paragraph summary."
      :key_facts -> "List the key facts as numbered points."
      _ -> "Use a clear, organized format."
    end

    prompt = """
    Create a study summary of this content:

    Content:
    ---
    #{content}
    ---

    #{format_instruction}

    Focus on:
    - Key concepts and ideas
    - Important facts and figures
    - Relationships between concepts
    - Anything likely to be tested

    Keep it concise but comprehensive.
    """

    case AiEngine.generate(prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Compare and contrast two concepts.
  """
  def compare(concept1, concept2) do
    prompt = """
    Compare and contrast these two concepts:

    1. #{concept1}
    2. #{concept2}

    Provide:
    - SIMILARITIES: What they have in common
    - DIFFERENCES: How they differ
    - KEY INSIGHT: One important takeaway about their relationship

    Be clear and educational.
    """

    case AiEngine.generate(prompt, max_new_tokens: 500) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Generate mnemonic devices for memorization.
  """
  def mnemonic(content, opts \\ []) do
    type = Keyword.get(opts, :type, :acronym)

    type_instruction = case type do
      :acronym -> "Create an acronym (first letters spell a word)."
      :acrostic -> "Create an acrostic (first letters of a sentence spell the word)."
      :rhyme -> "Create a rhyme or song to remember."
      :story -> "Create a short memorable story."
      :visual -> "Describe a visual association technique."
      _ -> "Create a memorable way to remember this."
    end

    prompt = """
    Create a mnemonic device to remember:

    #{content}

    #{type_instruction}

    Make it memorable and easy to recall.
    Explain how to use it.
    """

    case AiEngine.generate(prompt, max_new_tokens: 300) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Break down a complex topic into simpler parts.
  """
  def breakdown(topic, opts \\ []) do
    steps = Keyword.get(opts, :steps, 5)

    prompt = """
    Break down this complex topic into #{steps} simple, understandable parts:

    Topic: #{topic}

    For each part:
    - Give it a clear title
    - Explain it simply
    - Show how it connects to the other parts

    Start from the basics and build up to the full understanding.
    """

    case AiEngine.generate(prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Generate practice problems.
  """
  def practice_problems(topic, opts \\ []) do
    count = Keyword.get(opts, :count, 5)
    difficulty = Keyword.get(opts, :difficulty, :medium)

    difficulty_instruction = case difficulty do
      :easy -> "Make these beginner-friendly problems."
      :medium -> "Make these intermediate level problems."
      :hard -> "Make these challenging problems."
      _ -> "Make these medium difficulty problems."
    end

    prompt = """
    Generate #{count} practice problems about: #{topic}

    #{difficulty_instruction}

    Format each problem as:
    PROBLEM #N:
    [problem statement]

    SOLUTION:
    [step-by-step solution]
    ---

    Make problems that build understanding progressively.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  # Private helpers

  defp parse_flashcards(text) do
    text
    |> String.split("---")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn card ->
      case Regex.run(~r/FRONT:\s*(.+?)(?:\r?\n|\z).*?BACK:\s*(.+?)(?:\r?\n|\z|$)/is, card) do
        [_, front, back] -> %{front: String.trim(front), back: String.trim(back)}
        _ ->
          # Try alternative format
          lines = String.split(card, "\n", parts: 2)
          case lines do
            [front, back] -> %{front: String.trim(front), back: String.trim(back)}
            [single] -> %{front: String.trim(single), back: ""}
            _ -> nil
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(20)
  end

  defp parse_quiz(text, _type) do
    text
    |> String.split("---")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn question_block ->
      lines = String.split(question_block, "\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

      case lines do
        [q | rest] ->
          question = String.replace(q, ~r/^Q:\s*/, "")
          answer = rest
          |> Enum.find(fn line -> String.starts_with?(line, "*") or String.starts_with?(line, "A:") end)
          |> case do
            nil -> Enum.join(rest, "\n")
            a -> String.replace(a, ~r/^[\*A]:\s*/, "")
          end
          options = rest
          |> Enum.filter(fn line ->
            Regex.match?(~r/^[A-D\*]\)/, line)
          end)

          %{question: question, answer: answer, options: options}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
