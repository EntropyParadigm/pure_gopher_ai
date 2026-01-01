defmodule PureGopherAi.WritingAssistant do
  @moduledoc """
  AI-powered writing assistant for helping users draft, improve, and polish content.

  Features:
  - Draft generation from topic or outline
  - Style improvement suggestions
  - Grammar and spelling assistance
  - Tone adjustment (formal, casual, technical)
  - Auto-generate titles and tags
  - Content expansion and compression
  """

  alias PureGopherAi.AiEngine

  @tones [:formal, :casual, :technical, :friendly, :professional, :creative]
  @styles [:academic, :blog, :news, :story, :tutorial, :review]

  @doc """
  Returns available writing tones.
  """
  def tones, do: @tones

  @doc """
  Returns available writing styles.
  """
  def styles, do: @styles

  @doc """
  Generate a draft from a topic or outline.
  """
  def draft(topic, opts \\ []) do
    style = Keyword.get(opts, :style, :blog)
    tone = Keyword.get(opts, :tone, :casual)
    length = Keyword.get(opts, :length, :medium)

    length_instruction = case length do
      :short -> "Keep it brief, around 2-3 paragraphs."
      :medium -> "Write a moderate length piece, around 4-6 paragraphs."
      :long -> "Write a comprehensive piece with 8+ paragraphs."
      _ -> "Write a moderate length piece."
    end

    prompt = """
    You are a skilled writer. Generate a #{style} article draft about the following topic.

    Topic/Outline: #{topic}

    Writing Style: #{style}
    Tone: #{tone}
    #{length_instruction}

    Write the content directly without any preamble or explanation.
    Focus on engaging, well-structured content.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Improve the style and flow of existing content.
  """
  def improve(content, opts \\ []) do
    focus = Keyword.get(opts, :focus, :all)

    focus_instruction = case focus do
      :clarity -> "Focus on making the writing clearer and easier to understand."
      :flow -> "Focus on improving the flow and transitions between ideas."
      :engagement -> "Focus on making the writing more engaging and interesting."
      :conciseness -> "Focus on making the writing more concise without losing meaning."
      :all -> "Improve clarity, flow, engagement, and conciseness."
      _ -> "Improve the overall quality of the writing."
    end

    prompt = """
    You are an expert editor. Improve the following content.

    #{focus_instruction}

    Original content:
    ---
    #{content}
    ---

    Provide the improved version directly without explanations.
    Maintain the original meaning and key points.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Proofread content for grammar, spelling, and punctuation.
  """
  def proofread(content) do
    prompt = """
    You are a professional proofreader. Review the following text for:
    - Grammar errors
    - Spelling mistakes
    - Punctuation issues
    - Awkward phrasing

    Text to review:
    ---
    #{content}
    ---

    Return the corrected text directly. If there are significant issues, briefly note them at the end.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Adjust the tone of content.
  """
  def adjust_tone(content, target_tone) when target_tone in @tones do
    tone_description = case target_tone do
      :formal -> "formal, professional, and polished"
      :casual -> "casual, conversational, and approachable"
      :technical -> "technical, precise, and detailed"
      :friendly -> "friendly, warm, and personable"
      :professional -> "professional, balanced, and authoritative"
      :creative -> "creative, expressive, and unique"
    end

    prompt = """
    You are a skilled writer. Rewrite the following content to have a #{tone_description} tone.

    Original content:
    ---
    #{content}
    ---

    Rewrite maintaining the same information but adjusting the tone.
    Provide only the rewritten content.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  def adjust_tone(_content, _tone), do: {:error, :invalid_tone}

  @doc """
  Generate title suggestions for content.
  """
  def generate_titles(content, opts \\ []) do
    count = Keyword.get(opts, :count, 5)
    style = Keyword.get(opts, :style, :engaging)

    style_instruction = case style do
      :engaging -> "Create attention-grabbing, engaging titles."
      :descriptive -> "Create clear, descriptive titles."
      :creative -> "Create creative, unique titles."
      :seo -> "Create SEO-friendly titles with relevant keywords."
      _ -> "Create good titles."
    end

    prompt = """
    You are a skilled headline writer. Generate #{count} title suggestions for the following content.

    #{style_instruction}

    Content:
    ---
    #{content}
    ---

    List #{count} title options, one per line, numbered 1-#{count}.
    """

    case AiEngine.generate(prompt, max_new_tokens: 200) do
      {:ok, result} ->
        titles = result
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&clean_title_line/1)
        |> Enum.take(count)

        {:ok, titles}

      error -> error
    end
  end

  @doc """
  Generate tags/keywords for content.
  """
  def generate_tags(content, opts \\ []) do
    count = Keyword.get(opts, :count, 8)

    prompt = """
    You are an expert at content categorization. Generate #{count} relevant tags for the following content.

    Content:
    ---
    #{content}
    ---

    List #{count} tags, one per line. Use lowercase, single words or short phrases.
    Focus on topics, themes, and key concepts.
    """

    case AiEngine.generate(prompt, max_new_tokens: 150) do
      {:ok, result} ->
        tags = result
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&clean_tag/1)
        |> Enum.take(count)

        {:ok, tags}

      error -> error
    end
  end

  @doc """
  Expand content to be more detailed and comprehensive.
  """
  def expand(content, opts \\ []) do
    factor = Keyword.get(opts, :factor, 2)
    focus = Keyword.get(opts, :focus, nil)

    focus_instruction = if focus do
      "Focus especially on expanding the sections about: #{focus}"
    else
      "Expand all sections proportionally."
    end

    prompt = """
    You are a skilled writer. Expand the following content to be approximately #{factor}x longer.

    #{focus_instruction}

    Add more:
    - Details and examples
    - Explanations and context
    - Supporting points

    Original content:
    ---
    #{content}
    ---

    Provide the expanded content directly.
    """

    case AiEngine.generate(prompt, max_new_tokens: 1000) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Compress content to be more concise.
  """
  def compress(content, opts \\ []) do
    target = Keyword.get(opts, :target, :half)

    target_instruction = case target do
      :summary -> "Create a brief summary (1-2 sentences)."
      :quarter -> "Reduce to about 25% of the original length."
      :half -> "Reduce to about 50% of the original length."
      :tldr -> "Create a TL;DR version (1-3 sentences)."
      _ -> "Make it more concise while keeping key points."
    end

    prompt = """
    You are a skilled editor. #{target_instruction}

    Original content:
    ---
    #{content}
    ---

    Maintain the key information and main points.
    Provide the compressed content directly.
    """

    case AiEngine.generate(prompt, max_new_tokens: 500) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Generate an outline from a topic.
  """
  def outline(topic, opts \\ []) do
    depth = Keyword.get(opts, :depth, 2)
    style = Keyword.get(opts, :style, :blog)

    prompt = """
    You are a skilled writer. Create a detailed outline for a #{style} article about:

    Topic: #{topic}

    Create an outline with #{depth} levels of depth.
    Use clear headings and subheadings.
    Include key points to cover under each section.
    """

    case AiEngine.generate(prompt, max_new_tokens: 400) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Generate a conclusion for content.
  """
  def conclude(content, opts \\ []) do
    style = Keyword.get(opts, :style, :summary)

    style_instruction = case style do
      :summary -> "Summarize the key points"
      :call_to_action -> "End with a compelling call to action"
      :reflection -> "End with a thoughtful reflection"
      :forward_looking -> "End with forward-looking thoughts"
      _ -> "Create an appropriate conclusion"
    end

    prompt = """
    You are a skilled writer. Write a conclusion for the following content.

    #{style_instruction}

    Content:
    ---
    #{content}
    ---

    Write only the conclusion paragraph.
    """

    case AiEngine.generate(prompt, max_new_tokens: 200) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Generate an introduction for content.
  """
  def introduce(content, opts \\ []) do
    style = Keyword.get(opts, :style, :hook)

    style_instruction = case style do
      :hook -> "Start with an engaging hook to draw readers in"
      :context -> "Provide context and background"
      :question -> "Start with a thought-provoking question"
      :story -> "Start with a brief anecdote or story"
      _ -> "Create an engaging introduction"
    end

    prompt = """
    You are a skilled writer. Write an introduction for the following content.

    #{style_instruction}

    Content:
    ---
    #{content}
    ---

    Write only the introduction paragraph.
    """

    case AiEngine.generate(prompt, max_new_tokens: 200) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  # Private helpers

  defp clean_title_line(line) do
    line
    |> String.replace(~r/^\d+[\.\)]\s*/, "")
    |> String.replace(~r/^[-•]\s*/, "")
    |> String.trim()
  end

  defp clean_tag(tag) do
    tag
    |> String.replace(~r/^\d+[\.\)]\s*/, "")
    |> String.replace(~r/^[-•]\s*/, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\-\s]/, "")
    |> String.trim()
  end
end
