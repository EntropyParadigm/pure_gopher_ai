defmodule PureGopherAi.Recovery do
  @moduledoc """
  Account recovery system using mnemonic recovery phrases.

  Generates a set of random words during account creation that can be
  used to recover the account and set a new passphrase.
  """

  # BIP39-style word list (simplified, 256 common English words)
  @word_list ~w[
    abandon ability able about above absent absorb abstract absurd abuse
    access accident account accuse achieve acid acoustic acquire across act
    action actor actress actual adapt add addict address adjust admit adult
    advance advice aerobic affair afford afraid again age agent agree ahead
    aim air airport aisle alarm album alcohol alert alien all alley allow
    almost alone alpha already also alter always amateur amazing among amount
    amused analyst anchor ancient anger angle angry animal ankle announce
    annual another answer antenna antique anxiety any apart apology appear
    apple approve april arch arctic area arena argue arm armed armor army
    around arrange arrest arrive arrow art artefact artist artwork ask aspect
    assault asset assist assume asthma athlete atom attack attend attitude
    attract auction audit august aunt author auto autumn average avocado
    avoid awake aware away awesome awful awkward axis baby bachelor bacon
    badge bag balance balcony ball bamboo banana banner bar barely bargain
    barrel base basic basket battle beach bean beauty because become beef
    before begin behave behind believe below belt bench benefit best betray
    better between beyond bicycle bid bike bind biology bird birth bitter
    black blade blame blanket blast bleak bless blind blood blossom blouse
    blue blur blush board boat body boil bomb bone bonus book boost border
    boring borrow boss bottom bounce box boy bracket brain brand brass brave
    bread breeze brick bridge brief bright bring brisk broccoli broken bronze
    broom brother brown brush bubble buddy budget buffalo build bulb bulk
    bullet bundle bunker burden burger burst bus business busy butter buyer
  ]

  @recovery_phrase_length 12

  @doc """
  Generates a new recovery phrase.
  Returns a list of words.
  """
  def generate_phrase do
    1..@recovery_phrase_length
    |> Enum.map(fn _ -> Enum.random(@word_list) end)
  end

  @doc """
  Formats a recovery phrase for display.
  """
  def format_phrase(words) when is_list(words) do
    words
    |> Enum.with_index(1)
    |> Enum.map(fn {word, i} -> "#{i}. #{word}" end)
    |> Enum.join("\n")
  end

  @doc """
  Hashes a recovery phrase for storage.
  """
  def hash_phrase(words) when is_list(words) do
    phrase = Enum.join(words, " ") |> String.downcase()
    :crypto.hash(:sha256, phrase) |> Base.encode64()
  end

  @doc """
  Verifies a recovery phrase against its hash.
  """
  def verify_phrase(words, stored_hash) when is_list(words) do
    computed_hash = hash_phrase(words)
    :crypto.hash_equals(stored_hash, computed_hash)
  end

  @doc """
  Parses a recovery phrase from user input.
  Handles various input formats (space-separated, numbered list, etc.)
  """
  def parse_input(input) when is_binary(input) do
    words = input
      |> String.downcase()
      |> String.replace(~r/\d+\.\s*/, "")  # Remove numbered prefixes
      |> String.replace(~r/[,;\n\r\t]+/, " ")  # Normalize separators
      |> String.split(~r/\s+/, trim: true)  # Split on whitespace
      |> Enum.filter(&valid_word?/1)

    if length(words) == @recovery_phrase_length do
      {:ok, words}
    else
      {:error, :invalid_phrase_length}
    end
  end

  @doc """
  Checks if a word is in the word list.
  """
  def valid_word?(word), do: String.downcase(word) in @word_list

  @doc """
  Returns the expected phrase length.
  """
  def phrase_length, do: @recovery_phrase_length
end
