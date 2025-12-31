defmodule PureGopherAi.Utilities do
  @moduledoc """
  Quick utilities and fun tools for the Gopher server.

  Includes:
  - Dice roller
  - Magic 8-ball
  - Random number generator
  - Coin flip
  - UUID generator
  - Hash calculator
  - Base64 encoder/decoder
  - ROT13
  - Password generator
  - Timestamp converter
  """

  @magic_8ball_answers [
    # Affirmative
    "It is certain.",
    "It is decidedly so.",
    "Without a doubt.",
    "Yes, definitely.",
    "You may rely on it.",
    "As I see it, yes.",
    "Most likely.",
    "Outlook good.",
    "Yes.",
    "Signs point to yes.",
    # Non-committal
    "Reply hazy, try again.",
    "Ask again later.",
    "Better not tell you now.",
    "Cannot predict now.",
    "Concentrate and ask again.",
    # Negative
    "Don't count on it.",
    "My reply is no.",
    "My sources say no.",
    "Outlook not so good.",
    "Very doubtful."
  ]

  @doc """
  Rolls dice in NdM format (e.g., "2d6", "1d20", "3d10+5").
  Returns {:ok, %{rolls: [...], total: n, modifier: m}} or {:error, reason}.
  """
  def roll_dice(spec) do
    case parse_dice_spec(spec) do
      {:ok, count, sides, modifier} when count > 0 and count <= 100 and sides > 0 and sides <= 1000 ->
        rolls = for _ <- 1..count, do: :rand.uniform(sides)
        total = Enum.sum(rolls) + modifier
        {:ok, %{rolls: rolls, total: total, modifier: modifier, count: count, sides: sides}}

      {:ok, _, _, _} ->
        {:error, :invalid_spec}

      :error ->
        {:error, :parse_error}
    end
  end

  defp parse_dice_spec(spec) do
    spec = String.downcase(String.trim(spec))

    # Handle modifier (e.g., "2d6+3" or "2d6-2")
    {base, modifier} = case Regex.run(~r/^(.+?)([+-]\d+)$/, spec) do
      [_, base, mod_str] ->
        {base, String.to_integer(mod_str)}
      nil ->
        {spec, 0}
    end

    case Regex.run(~r/^(\d+)d(\d+)$/, base) do
      [_, count_str, sides_str] ->
        count = String.to_integer(count_str)
        sides = String.to_integer(sides_str)
        {:ok, count, sides, modifier}

      nil ->
        :error
    end
  end

  @doc """
  Shakes the magic 8-ball.
  """
  def magic_8ball do
    Enum.random(@magic_8ball_answers)
  end

  @doc """
  Generates a random number between min and max (inclusive).
  """
  def random_number(min, max) when min <= max do
    {:ok, :rand.uniform(max - min + 1) + min - 1}
  end

  def random_number(_, _), do: {:error, :invalid_range}

  @doc """
  Flips a coin.
  """
  def coin_flip do
    if :rand.uniform(2) == 1, do: :heads, else: :tails
  end

  @doc """
  Generates a UUID v4.
  """
  def generate_uuid do
    <<a1::4, a2::4, a3::4, a4::4, a5::4, a6::4, a7::4, a8::4,
      b1::4, b2::4, b3::4, b4::4,
      _::4, c2::4, c3::4, c4::4,
      _::2, d2::6,
      e1::4, e2::4,
      f1::4, f2::4, f3::4, f4::4, f5::4, f6::4,
      g1::4, g2::4, g3::4, g4::4, g5::4, g6::4>> = :crypto.strong_rand_bytes(16)

    # Set version to 4 and variant to 10
    hex = :io_lib.format(
      "~.16b~.16b~.16b~.16b~.16b~.16b~.16b~.16b-" <>
      "~.16b~.16b~.16b~.16b-" <>
      "4~.16b~.16b~.16b-" <>
      "~.16b~.16b~.16b-" <>
      "~.16b~.16b~.16b~.16b~.16b~.16b~.16b~.16b~.16b~.16b~.16b~.16b",
      [a1, a2, a3, a4, a5, a6, a7, a8,
       b1, b2, b3, b4,
       c2, c3, c4,
       8 + rem(d2, 4), rem(e1, 16), e2,
       f1, f2, f3, f4, f5, f6,
       g1, g2, g3, g4, g5, g6]
    )

    to_string(hex)
  end

  @doc """
  Calculates hash of input.
  Supported algorithms: md5, sha1, sha256, sha512
  """
  def calculate_hash(input, algorithm \\ :sha256) do
    algo = case algorithm do
      :md5 -> :md5
      :sha1 -> :sha
      :sha256 -> :sha256
      :sha512 -> :sha512
      _ -> :sha256
    end

    :crypto.hash(algo, input)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Encodes string to Base64.
  """
  def base64_encode(input) do
    Base.encode64(input)
  end

  @doc """
  Decodes Base64 string.
  """
  def base64_decode(input) do
    case Base.decode64(input) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  @doc """
  Applies ROT13 transformation.
  """
  def rot13(input) do
    input
    |> String.to_charlist()
    |> Enum.map(&rotate_char/1)
    |> to_string()
  end

  defp rotate_char(c) when c in ?A..?M or c in ?a..?m, do: c + 13
  defp rotate_char(c) when c in ?N..?Z or c in ?n..?z, do: c - 13
  defp rotate_char(c), do: c

  @doc """
  Generates a random password.
  """
  def generate_password(length \\ 16) do
    length = min(max(length, 8), 64)

    chars = String.graphemes("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+")

    1..length
    |> Enum.map(fn _ -> Enum.random(chars) end)
    |> Enum.join()
  end

  @doc """
  Converts unix timestamp to human-readable date.
  """
  def timestamp_to_date(timestamp) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, dt} -> {:ok, DateTime.to_string(dt)}
      error -> error
    end
  end

  def timestamp_to_date(_), do: {:error, :invalid_timestamp}

  @doc """
  Gets current unix timestamp.
  """
  def current_timestamp do
    System.system_time(:second)
  end

  @doc """
  Picks a random item from a list.
  """
  def random_pick(items) when is_list(items) and length(items) > 0 do
    {:ok, Enum.random(items)}
  end

  def random_pick(_), do: {:error, :empty_list}

  @doc """
  Shuffles a list of items.
  """
  def shuffle(items) when is_list(items) do
    Enum.shuffle(items)
  end

  @doc """
  Counts characters/words in text.
  """
  def count_text(text) do
    chars = String.length(text)
    words = text |> String.split(~r/\s+/, trim: true) |> length()
    lines = text |> String.split("\n") |> length()

    %{characters: chars, words: words, lines: lines}
  end
end
