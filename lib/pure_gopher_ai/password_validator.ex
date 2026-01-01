defmodule PureGopherAi.PasswordValidator do
  @moduledoc """
  Password/passphrase strength validation.

  Validates passphrase complexity and provides strength scoring.
  Designed for text-based Gopher interface - uses passphrases
  rather than complex character requirements.
  """

  @min_length 8
  @max_length 256
  @common_passwords ~w[
    password password1 password123 123456 12345678 qwerty letmein
    admin administrator root toor passw0rd p@ssword p@ssw0rd
    abc123 111111 1234567 iloveyou sunshine princess dragon
    monkey football baseball shadow master hello welcome
    gopher gopherspace test testing guest user login secret
  ]

  @doc """
  Validates a passphrase.
  Returns :ok or {:error, reason}
  """
  def validate(passphrase) when is_binary(passphrase) do
    cond do
      String.length(passphrase) < @min_length ->
        {:error, :too_short}

      String.length(passphrase) > @max_length ->
        {:error, :too_long}

      String.downcase(passphrase) in @common_passwords ->
        {:error, :too_common}

      all_same_char?(passphrase) ->
        {:error, :too_simple}

      sequential_chars?(passphrase) ->
        {:error, :sequential}

      repeated_pattern?(passphrase) ->
        {:error, :repeated_pattern}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, :invalid}

  @doc """
  Calculates a strength score from 0-100.
  """
  def strength_score(passphrase) when is_binary(passphrase) do
    length_score = min(String.length(passphrase) * 3, 30)
    variety_score = character_variety_score(passphrase)
    entropy_score = entropy_score(passphrase)

    min(length_score + variety_score + entropy_score, 100)
  end

  def strength_score(_), do: 0

  @doc """
  Returns a human-readable strength label.
  """
  def strength_label(passphrase) do
    score = strength_score(passphrase)

    cond do
      score >= 80 -> "Strong"
      score >= 60 -> "Good"
      score >= 40 -> "Fair"
      score >= 20 -> "Weak"
      true -> "Very Weak"
    end
  end

  @doc """
  Returns validation error message.
  """
  def error_message(:too_short), do: "Passphrase must be at least #{@min_length} characters"
  def error_message(:too_long), do: "Passphrase must be at most #{@max_length} characters"
  def error_message(:too_common), do: "This passphrase is too common. Please choose something unique"
  def error_message(:too_simple), do: "Passphrase is too simple (all same character)"
  def error_message(:sequential), do: "Passphrase contains sequential characters (abc, 123)"
  def error_message(:repeated_pattern), do: "Passphrase contains repeated patterns"
  def error_message(:invalid), do: "Invalid passphrase"
  def error_message(_), do: "Passphrase does not meet requirements"

  @doc """
  Returns passphrase requirements as a list of strings.
  """
  def requirements do
    [
      "At least #{@min_length} characters long",
      "Not a common password",
      "No repeated patterns",
      "Tip: Use a memorable phrase or sentence"
    ]
  end

  # Private functions

  defp all_same_char?(str) do
    chars = String.graphemes(str)
    Enum.uniq(chars) |> length() == 1
  end

  defp sequential_chars?(str) do
    str = String.downcase(str)

    # Check for sequential patterns
    sequential_patterns = [
      "abc", "bcd", "cde", "def", "efg", "fgh", "ghi", "hij",
      "ijk", "jkl", "klm", "lmn", "mno", "nop", "opq", "pqr",
      "qrs", "rst", "stu", "tuv", "uvw", "vwx", "wxy", "xyz",
      "123", "234", "345", "456", "567", "678", "789", "890",
      "qwe", "wer", "ert", "rty", "tyu", "yui", "uio", "iop",
      "asd", "sdf", "dfg", "fgh", "ghj", "hjk", "jkl",
      "zxc", "xcv", "cvb", "vbn", "bnm"
    ]

    Enum.any?(sequential_patterns, &String.contains?(str, &1))
  end

  defp repeated_pattern?(str) do
    len = String.length(str)

    if len < 4 do
      false
    else
      # Check for patterns that repeat more than half the string
      Enum.any?(1..div(len, 2), fn pattern_len ->
        pattern = String.slice(str, 0, pattern_len)
        repeated = String.duplicate(pattern, div(len, pattern_len) + 1)
        String.starts_with?(repeated, str) and pattern_len < len
      end)
    end
  end

  defp character_variety_score(str) do
    has_lower = String.match?(str, ~r/[a-z]/)
    has_upper = String.match?(str, ~r/[A-Z]/)
    has_digit = String.match?(str, ~r/[0-9]/)
    has_special = String.match?(str, ~r/[^a-zA-Z0-9]/)
    has_space = String.contains?(str, " ")

    variety = [has_lower, has_upper, has_digit, has_special, has_space]
      |> Enum.count(& &1)

    variety * 10
  end

  defp entropy_score(str) do
    unique_chars = String.graphemes(str) |> Enum.uniq() |> length()
    total_chars = String.length(str)

    # Ratio of unique chars to total chars
    ratio = unique_chars / max(total_chars, 1)

    round(ratio * 20)
  end
end
