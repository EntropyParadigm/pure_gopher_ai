defmodule PureGopherAi.RequestValidator do
  @moduledoc """
  Request validation for Gopher and Gemini protocols.

  Provides size limits, complexity checks, and basic request validation
  to prevent abuse and DoS attacks.

  ## Features
  - Selector/path length limits
  - Query length limits
  - Special character detection
  - Unicode complexity limits
  - Path traversal prevention
  """

  @max_selector_length 1024
  @max_query_length 4000
  @max_url_length 2048
  @max_special_char_ratio 0.3
  @max_unicode_ratio 0.5

  # Blocked path patterns that could be dangerous
  @blocked_patterns [
    ~r/\.\./,                    # Path traversal
    ~r/\/\//,                    # Double slashes
    ~r/[\x00\x1b]/,              # Null bytes and escape chars
    ~r/%00|%1b/i,                # URL-encoded null/escape
    ~r/\$\(|`/,                  # Command injection
    ~r/<script/i,                # XSS attempt (unlikely but safe)
  ]

  @doc """
  Validates a Gopher selector.

  Returns `{:ok, selector}` if valid, or `{:error, reason}` if invalid.

  ## Examples

      iex> RequestValidator.validate_selector("/ask hello")
      {:ok, "/ask hello"}

      iex> RequestValidator.validate_selector("../../../etc/passwd")
      {:error, :blocked_pattern}
  """
  def validate_selector(selector) when is_binary(selector) do
    cond do
      String.length(selector) > @max_selector_length ->
        {:error, :selector_too_long}

      contains_blocked_pattern?(selector) ->
        {:error, :blocked_pattern}

      has_excessive_special_chars?(selector) ->
        {:error, :too_many_special_chars}

      has_excessive_unicode?(selector) ->
        {:error, :too_much_unicode}

      true ->
        {:ok, selector}
    end
  end

  def validate_selector(nil), do: {:ok, ""}
  def validate_selector(_), do: {:error, :invalid_selector}

  @doc """
  Validates a query string (the part after /ask, /chat, etc.).

  Returns `{:ok, query}` if valid, or `{:error, reason}` if invalid.
  """
  def validate_query(query) when is_binary(query) do
    cond do
      String.length(query) > @max_query_length ->
        {:error, :query_too_long}

      contains_blocked_pattern?(query) ->
        {:error, :blocked_pattern}

      # Allow more special chars in queries but not excessive
      special_char_ratio(query) > 0.5 ->
        {:error, :too_many_special_chars}

      true ->
        {:ok, query}
    end
  end

  def validate_query(nil), do: {:ok, ""}
  def validate_query(_), do: {:error, :invalid_query}

  @doc """
  Validates a Gemini URL.

  Returns `{:ok, url}` if valid, or `{:error, reason}` if invalid.
  """
  def validate_gemini_url(url) when is_binary(url) do
    cond do
      String.length(url) > @max_url_length ->
        {:error, :url_too_long}

      not String.starts_with?(url, ["gemini://", "/"]) ->
        {:error, :invalid_scheme}

      contains_blocked_pattern?(url) ->
        {:error, :blocked_pattern}

      true ->
        {:ok, url}
    end
  end

  def validate_gemini_url(_), do: {:error, :invalid_url}

  @doc """
  Validates a path component (used for file access, phlog entries, etc.).

  Returns `{:ok, path}` if valid, or `{:error, reason}` if invalid.
  """
  def validate_path(path) when is_binary(path) do
    cond do
      String.length(path) > 512 ->
        {:error, :path_too_long}

      String.contains?(path, "..") ->
        {:error, :path_traversal}

      String.contains?(path, "\0") ->
        {:error, :null_byte}

      String.contains?(path, ["//", "\\"]) ->
        {:error, :invalid_path}

      true ->
        {:ok, path}
    end
  end

  def validate_path(nil), do: {:error, :missing_path}
  def validate_path(_), do: {:error, :invalid_path}

  @doc """
  Validates user-provided content (guestbook, bulletin board, etc.).

  Options:
  - `:max_length` - Maximum content length (default: 4000)
  - `:allow_newlines` - Allow newline characters (default: true)
  - `:require_content` - Require non-empty content (default: true)
  """
  def validate_content(content, opts \\ []) when is_binary(content) do
    max_length = Keyword.get(opts, :max_length, 4000)
    allow_newlines = Keyword.get(opts, :allow_newlines, true)
    require_content = Keyword.get(opts, :require_content, true)

    trimmed = String.trim(content)

    cond do
      require_content and trimmed == "" ->
        {:error, :empty_content}

      String.length(content) > max_length ->
        {:error, :content_too_long}

      not allow_newlines and String.contains?(content, ["\n", "\r"]) ->
        {:error, :newlines_not_allowed}

      contains_blocked_pattern?(content) ->
        {:error, :blocked_pattern}

      true ->
        {:ok, trimmed}
    end
  end

  def validate_content(nil, _opts), do: {:error, :missing_content}
  def validate_content(_, _opts), do: {:error, :invalid_content}

  @doc """
  Validates a name/username field.
  """
  def validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      String.length(trimmed) < 1 ->
        {:error, :name_too_short}

      String.length(trimmed) > 50 ->
        {:error, :name_too_long}

      String.match?(trimmed, ~r/[\x00-\x1F\x7F]/) ->
        {:error, :invalid_characters}

      true ->
        {:ok, trimmed}
    end
  end

  def validate_name(nil), do: {:ok, "Anonymous"}
  def validate_name(_), do: {:error, :invalid_name}

  @doc """
  Returns validation statistics for monitoring.
  """
  def analyze_request(input) when is_binary(input) do
    %{
      length: String.length(input),
      special_char_ratio: special_char_ratio(input),
      unicode_ratio: unicode_ratio(input),
      has_blocked_pattern: contains_blocked_pattern?(input),
      has_null_bytes: String.contains?(input, "\0"),
      has_control_chars: String.match?(input, ~r/[\x00-\x1F\x7F]/)
    }
  end

  def analyze_request(_), do: %{error: :invalid_input}

  # Private functions

  defp contains_blocked_pattern?(text) do
    Enum.any?(@blocked_patterns, &Regex.match?(&1, text))
  end

  defp has_excessive_special_chars?(text) do
    special_char_ratio(text) > @max_special_char_ratio
  end

  defp has_excessive_unicode?(text) do
    unicode_ratio(text) > @max_unicode_ratio
  end

  defp special_char_ratio(text) when byte_size(text) == 0, do: 0.0

  defp special_char_ratio(text) do
    graphemes = String.graphemes(text)
    total = length(graphemes)

    if total == 0 do
      0.0
    else
      special =
        Enum.count(graphemes, fn g ->
          # Count chars that aren't alphanumeric, space, or common punctuation
          not String.match?(g, ~r/^[a-zA-Z0-9\s.,!?'"():;\-\/]$/)
        end)

      special / total
    end
  end

  defp unicode_ratio(text) when byte_size(text) == 0, do: 0.0

  defp unicode_ratio(text) do
    graphemes = String.graphemes(text)
    total = length(graphemes)

    if total == 0 do
      0.0
    else
      non_ascii =
        Enum.count(graphemes, fn g ->
          String.match?(g, ~r/[^\x00-\x7F]/)
        end)

      non_ascii / total
    end
  end
end
