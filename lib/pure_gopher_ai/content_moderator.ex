defmodule PureGopherAi.ContentModerator do
  @moduledoc """
  AI-powered content moderation for user-submitted content.

  Only blocks highly illegal content:
  - Child sexual abuse material (CSAM)
  - Terrorism/violence incitement
  - Explicit instructions for serious violence

  Approach: Transparent auto-approval unless AI flags content as highly illegal.
  Does NOT moderate: opinions, politics, legal adult content, controversial topics.
  """

  require Logger

  alias PureGopherAi.AiEngine

  @doc """
  Checks content for highly illegal material.
  Returns {:ok, :approved} or {:error, :blocked, reason}.

  Content types: :phlog_post, :message, :comment, :paste
  """
  def check(content, content_type \\ :text) when is_binary(content) do
    # Skip very short content (likely not problematic)
    if String.length(content) < 10 do
      {:ok, :approved}
    else
      check_with_ai(content, content_type)
    end
  end

  def check(nil, _content_type), do: {:ok, :approved}
  def check("", _content_type), do: {:ok, :approved}

  @doc """
  Checks multiple pieces of content at once.
  Returns {:ok, :approved} if all pass, or {:error, :blocked, reason} on first failure.
  """
  def check_all(contents, content_type \\ :text) when is_list(contents) do
    combined = Enum.join(contents, "\n\n")
    check(combined, content_type)
  end

  # Private functions

  defp check_with_ai(content, content_type) do
    # Truncate very long content for moderation check
    content_to_check = String.slice(content, 0, 2000)

    prompt = build_moderation_prompt(content_to_check, content_type)

    try do
      # Use generate with short max tokens for quick response
      case AiEngine.generate(prompt, max_new_tokens: 50) do
        {:ok, response} ->
          parse_moderation_response(response)

        {:error, reason} ->
          # On AI error, log and allow content (fail open to avoid blocking legitimate content)
          Logger.warning("[ContentModerator] AI check failed: #{inspect(reason)}, allowing content")
          {:ok, :approved}
      end
    rescue
      e ->
        Logger.error("[ContentModerator] Exception during moderation: #{inspect(e)}")
        # Fail open - don't block content due to technical issues
        {:ok, :approved}
    end
  end

  defp build_moderation_prompt(content, content_type) do
    type_str = case content_type do
      :phlog_post -> "blog post"
      :message -> "private message"
      :comment -> "comment"
      :paste -> "paste/code snippet"
      _ -> "text"
    end

    """
    You are a content safety classifier. Analyze this user-submitted #{type_str} for ONLY highly illegal material.

    Check ONLY for:
    - Child sexual abuse material (CSAM) or explicit references to child exploitation
    - Terrorism recruitment, planning, or instructions for attacks
    - Explicit detailed instructions for mass violence or murder

    Do NOT flag:
    - Legal adult content
    - Political opinions (even extreme ones)
    - Controversial topics or debates
    - Fiction or creative writing
    - Historical discussions
    - News or journalism
    - Criticism or complaints

    Respond with ONLY one word:
    - "SAFE" if the content is acceptable
    - "BLOCK" if the content contains highly illegal material as defined above

    Content to analyze:
    ---
    #{content}
    ---

    Your classification (SAFE or BLOCK):
    """
  end

  defp parse_moderation_response(response) do
    response_clean = response
      |> String.trim()
      |> String.upcase()
      |> String.split()
      |> List.first() || ""

    cond do
      String.starts_with?(response_clean, "SAFE") ->
        {:ok, :approved}

      String.starts_with?(response_clean, "BLOCK") ->
        Logger.warning("[ContentModerator] Content blocked by AI moderation")
        {:error, :blocked, "Content violates community guidelines"}

      true ->
        # Unclear response, default to allowing (fail open)
        Logger.warning("[ContentModerator] Unclear AI response: #{response_clean}, allowing content")
        {:ok, :approved}
    end
  end

  @doc """
  Quick check for obvious patterns without using AI.
  Used as a fast pre-filter before AI moderation.
  Returns {:ok, :pass} or {:error, :blocked, reason}.
  """
  def quick_pattern_check(content) when is_binary(content) do
    content_lower = String.downcase(content)

    # Only block extremely obvious patterns that are never legitimate
    # Be very conservative to avoid false positives
    blocked_patterns = [
      # CSAM-related (extremely specific)
      ~r/\bcp\s+links?\b/i,
      ~r/\bpedo\s+(content|videos?|pics?|images?)\b/i
    ]

    matched = Enum.find(blocked_patterns, fn pattern ->
      Regex.match?(pattern, content_lower)
    end)

    if matched do
      Logger.warning("[ContentModerator] Quick pattern check blocked content")
      {:error, :blocked, "Content violates community guidelines"}
    else
      {:ok, :pass}
    end
  end

  def quick_pattern_check(_), do: {:ok, :pass}

  @doc """
  Full moderation check: quick pattern check + AI check.
  """
  def moderate(content, content_type \\ :text) do
    case quick_pattern_check(content) do
      {:ok, :pass} -> check(content, content_type)
      error -> error
    end
  end
end
