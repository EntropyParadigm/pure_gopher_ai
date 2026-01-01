defmodule PureGopherAi.InputSanitizer do
  @moduledoc """
  Centralized input sanitization and prompt injection defense.

  Provides multiple layers of protection:
  - Control character removal
  - Null byte stripping
  - Unicode normalization (prevents homoglyph attacks)
  - Prompt injection pattern detection
  - Length limits

  ## Usage

      iex> InputSanitizer.sanitize("  Hello World  ")
      "Hello World"

      iex> InputSanitizer.sanitize_prompt("Ignore previous instructions")
      {:blocked, "Input contains disallowed patterns"}

      iex> InputSanitizer.sanitize_prompt("What is the weather?")
      {:ok, "What is the weather?"}
  """

  @default_max_length 2000
  @prompt_max_length 4000

  # Prompt injection patterns to detect and block
  # These patterns are commonly used to manipulate AI behavior
  @injection_patterns [
    # Instruction override attempts
    ~r/ignore\s+(previous|above|all|prior|earlier)\s+instructions?/i,
    ~r/disregard\s+(previous|above|all|prior|earlier)/i,
    ~r/forget\s+(everything|what|your|all|previous)/i,
    ~r/override\s+(previous|your|all|system)/i,

    # Role manipulation
    ~r/you\s+are\s+now\s+(a|an|the|no\s+longer)/i,
    ~r/pretend\s+(you\s+are|to\s+be|you're)/i,
    ~r/act\s+as\s+(if|a|an|the)/i,
    ~r/roleplay\s+as/i,
    ~r/from\s+now\s+on\s+you/i,

    # System prompt injection
    ~r/new\s+instructions?:/i,
    ~r/system\s*:\s*\w/i,
    ~r/\[\s*SYSTEM\s*\]/i,
    ~r/\[\s*INST\s*\]/i,
    ~r/<<\s*SYS\s*>>/i,
    ~r/<\|system\|>/i,
    ~r/<\/?system>/i,
    ~r/<\/?assistant>/i,
    ~r/<\/?user>/i,

    # Template/variable injection
    ~r/\{\{\s*.*\s*\}\}/,
    ~r/\$\{[^}]+\}/,
    ~r/\{%\s*.*\s*%\}/,

    # Delimiter escape attempts
    ~r/```\s*(system|assistant|user)/i,
    ~r/---\s*(system|new\s+context)/i,

    # Jailbreak keywords
    ~r/DAN\s*mode/i,
    ~r/developer\s+mode\s+(enabled|on|activate)/i,
    ~r/jailbreak/i,
    ~r/bypass\s+(safety|filter|restriction)/i
  ]

  # Suspicious but not blocked patterns (for logging/monitoring)
  @suspicious_patterns [
    ~r/do\s+not\s+mention/i,
    ~r/never\s+say/i,
    ~r/always\s+respond/i,
    ~r/secret\s+(instruction|prompt|mode)/i
  ]

  @doc """
  Sanitizes general text input by removing dangerous characters.

  ## Options
    - `:max_length` - Maximum allowed length (default: 2000)
    - `:allow_newlines` - Whether to preserve newlines (default: true)

  ## Examples

      iex> InputSanitizer.sanitize("Hello\\x00World")
      "HelloWorld"

      iex> InputSanitizer.sanitize("  Trim me  ")
      "Trim me"
  """
  def sanitize(text, opts \\ [])
  def sanitize(nil, _opts), do: ""

  def sanitize(text, opts) when is_binary(text) do
    max_length = Keyword.get(opts, :max_length, @default_max_length)
    allow_newlines = Keyword.get(opts, :allow_newlines, true)

    text
    |> String.trim()
    |> remove_null_bytes()
    |> remove_control_chars(allow_newlines)
    |> normalize_unicode()
    |> collapse_whitespace()
    |> String.slice(0, max_length)
  end

  @doc """
  Sanitizes AI prompts with injection pattern detection.

  Returns `{:ok, sanitized_text}` if safe, or `{:blocked, reason}` if
  injection patterns are detected.

  ## Options
    - `:max_length` - Maximum prompt length (default: 4000)
    - `:strict` - Block suspicious patterns too (default: false)

  ## Examples

      iex> InputSanitizer.sanitize_prompt("What is 2+2?")
      {:ok, "What is 2+2?"}

      iex> InputSanitizer.sanitize_prompt("Ignore all previous instructions")
      {:blocked, "Input contains disallowed patterns"}
  """
  def sanitize_prompt(text, opts \\ [])
  def sanitize_prompt(nil, _opts), do: {:ok, ""}

  def sanitize_prompt(text, opts) when is_binary(text) do
    max_length = Keyword.get(opts, :max_length, @prompt_max_length)
    strict = Keyword.get(opts, :strict, false)

    sanitized = sanitize(text, max_length: max_length)

    cond do
      contains_injection?(sanitized) ->
        {:blocked, "Input contains disallowed patterns"}

      strict and contains_suspicious?(sanitized) ->
        {:blocked, "Input contains suspicious patterns"}

      true ->
        {:ok, sanitized}
    end
  end

  @doc """
  Checks if text contains prompt injection patterns.

  ## Examples

      iex> InputSanitizer.contains_injection?("Hello world")
      false

      iex> InputSanitizer.contains_injection?("Ignore previous instructions")
      true
  """
  def contains_injection?(text) when is_binary(text) do
    Enum.any?(@injection_patterns, &Regex.match?(&1, text))
  end

  def contains_injection?(_), do: false

  @doc """
  Checks if text contains suspicious (but not definitively malicious) patterns.
  """
  def contains_suspicious?(text) when is_binary(text) do
    Enum.any?(@suspicious_patterns, &Regex.match?(&1, text))
  end

  def contains_suspicious?(_), do: false

  @doc """
  Analyzes text and returns detected patterns for logging.

  ## Examples

      iex> InputSanitizer.analyze("Ignore all instructions")
      %{injection: true, suspicious: false, patterns: ["instruction override"]}
  """
  def analyze(text) when is_binary(text) do
    injection_matches =
      @injection_patterns
      |> Enum.filter(&Regex.match?(&1, text))
      |> Enum.map(&Regex.source/1)

    suspicious_matches =
      @suspicious_patterns
      |> Enum.filter(&Regex.match?(&1, text))
      |> Enum.map(&Regex.source/1)

    %{
      injection: length(injection_matches) > 0,
      suspicious: length(suspicious_matches) > 0,
      injection_patterns: injection_matches,
      suspicious_patterns: suspicious_matches,
      length: String.length(text),
      has_unicode: has_non_ascii?(text)
    }
  end

  def analyze(_), do: %{injection: false, suspicious: false, patterns: []}

  @doc """
  Escapes text for safe inclusion in Gopher protocol responses.

  Handles:
  - Premature response termination (lone dot on a line)
  - Tab characters (selector delimiters)
  - Carriage return/line feed normalization
  """
  def escape_gopher(text) when is_binary(text) do
    text
    # Normalize line endings to CRLF
    |> String.replace(~r/\r?\n/, "\r\n")
    # Escape lone dots at start of line (would terminate response)
    |> String.replace(~r/^\./m, "..")
    # Escape the termination sequence
    |> String.replace("\r\n.\r\n", "\r\n..\r\n")
    # Replace tabs with spaces (tabs are field delimiters in gopher)
    |> String.replace("\t", "    ")
  end

  def escape_gopher(nil), do: ""

  @doc """
  Escapes text for safe inclusion in Gemini protocol responses.
  """
  def escape_gemini(text) when is_binary(text) do
    text
    # Normalize line endings
    |> String.replace(~r/\r\n?/, "\n")
    # Escape preformatted toggle if not intended
    |> escape_gemini_preformat()
  end

  def escape_gemini(nil), do: ""

  # Private functions

  defp remove_null_bytes(text) do
    String.replace(text, "\0", "")
  end

  defp remove_control_chars(text, allow_newlines) do
    if allow_newlines do
      # Keep \n (0x0A) and \r (0x0D), remove other control chars
      String.replace(text, ~r/[\x00-\x09\x0B\x0C\x0E-\x1F\x7F]/, "")
    else
      String.replace(text, ~r/[\x00-\x1F\x7F]/, "")
    end
  end

  defp normalize_unicode(text) do
    text
    # Normalize to NFKC form (compatibility decomposition + canonical composition)
    |> String.normalize(:nfkc)
    # Remove zero-width characters that could be used for obfuscation
    |> String.replace(~r/[\x{200B}-\x{200F}\x{2028}-\x{202F}\x{2060}\x{FEFF}]/u, "")
    # Remove bidirectional override characters
    |> String.replace(~r/[\x{202A}-\x{202E}]/u, "")
  end

  defp collapse_whitespace(text) do
    # Collapse multiple spaces to single space (preserve newlines)
    text
    |> String.replace(~r/[^\S\r\n]+/, " ")
    # Remove excessive blank lines (more than 2 in a row)
    |> String.replace(~r/(\r?\n){3,}/, "\n\n")
  end

  defp has_non_ascii?(text) do
    String.match?(text, ~r/[^\x00-\x7F]/)
  end

  defp escape_gemini_preformat(text) do
    # Only escape ``` if it appears at the start of a line and isn't
    # already part of a preformatted block structure
    lines = String.split(text, "\n")
    in_preformat = false

    {escaped_lines, _} =
      Enum.reduce(lines, {[], in_preformat}, fn line, {acc, in_pre} ->
        if String.starts_with?(line, "```") do
          # Toggle preformat state, don't escape
          {[line | acc], not in_pre}
        else
          {[line | acc], in_pre}
        end
      end)

    escaped_lines
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
