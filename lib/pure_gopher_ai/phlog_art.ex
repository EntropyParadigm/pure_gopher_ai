defmodule PureGopherAi.PhlogArt do
  @moduledoc """
  ASCII art library for phlog illustrations.

  Provides themed ASCII art in medieval woodcut / 8-bit pixel art styles
  for decorating phlog posts. Includes both static templates and
  AI-generated custom illustrations.
  """

  alias PureGopherAi.AiEngine

  # Extended theme art library - multiple options per theme
  @art_library %{
    technology: [
      """
          ┌─────────────────┐
          │ ┌───┐   ┌───┐   │
          │ │ > │   │ < │   │
          │ └───┘   └───┘   │
          │   ╔═══════╗     │
          │   ║░░░░░░░║     │
          │   ║░01010░║     │
          │   ║░10101░║     │
          │   ╚═══════╝     │
          │  [___________]  │
          └─────────────────┘
      """,
      """
             .---.
            /     \\
            \\.@-@./
            /`\\_/`\\
           //  _  \\\\
          | \\     / |
           \\|  |  |/
            |  |  |
           /___|___\\
      """,
      """
          ╔════════════════╗
          ║  ██████████    ║
          ║  █ SYSTEM █    ║
          ║  ██████████    ║
          ║    ░░░░░░      ║
          ║   [______]     ║
          ╚════════════════╝
      """
    ],
    nature: [
      """
                  🌙
               .  *  .  *
            *    🌲    *
           .   🌲  🌲   .
          *  🌲🌲  🌲🌲  *
         . 🌲🌲🌲🌲🌲🌲🌲 .
        ═══════════════════
            ~~~  🦌  ~~~
      """,
      """
                 ( )
                (   )
                 ) (
                /   \\
               /     \\
              /_______\\
                 | |
            ~~~~|_|~~~~
      """,
      """
            ,
           /|      __
          / |   ,-~ /
         Y :|  //  /
         | jj /( .^
         >-"~"-v"
        /       Y
       jo  o    |
      ( ~T~     j
       >._-' _./
      /   "~"  |
             /   \\
            Y    Y
      """
    ],
    adventure: [
      """
               /\\
              /  \\
             / ⛰️ \\
            /      \\
           /   /\\   \\
          /   /  \\   \\
         /___/____\\___\\
             🚶➡️
        ~~~~~~~~~~~~~~~
      """,
      """
            ___________
           /           \\
          /  X marks    \\
         /   the spot    \\
        /      ╳          \\
       /___________________|
           /         \\
          /           \\
      """,
      """
              .     .
           .  |\\___/|  .
             /       \\
            | ⚔️   ⚔️ |
             \\_______/
              |     |
             /|     |\\
            / |     | \\
      """
    ],
    knowledge: [
      """
            ____________
           /            \\
          /   📚 📖 📚   \\
         /________________\\
         |  ═══════════  |
         |  KNOWLEDGE    |
         |  IS POWER     |
         |  ═══════════  |
         |________________|
      """,
      """
             _______
            /      //
           /      //
          /______//
          |  📖  |
          |______|
          | .  . |
          |______|
      """,
      """
            .d8888b.
           d88P  Y88b
           888    888
           888   📜
           888
           Y88b  d88P
            "Y8888P"
      """
    ],
    music: [
      """
           ♪ ♫ ♪ ♫ ♪
          ┌─────────┐
          │ ♩  ♬  ♩ │
          │ ═══════ │
          │  🎵     │
          │ ═══════ │
          └─────────┘
           ♫ ♪ ♫ ♪ ♫
      """,
      """
              ___
             /   \\
            |  O  |
            |     |
             \\___/
               |
               |
              /|\\
             / | \\
      """,
      """
           .-.
          (   )
           '-'
            |
        .---+---.
        |       |
        |  ~~~  |
        |       |
        '-------'
      """
    ],
    space: [
      """
           *  .  ★  .  *
         .    🌙     .
           ★       ★
              🚀
         .  ★    .    ★
           .   *   .
         *   .  ★  .   *
      """,
      """
              .  *
           *       .
         .    🪐      *
           *       .
         .     ★     .
           🌍
         *   .   *
      """,
      """
            ___
           /   \\
          | ★ ★ |
          |  ★  |
           \\___/
            | |
           /| |\\
          / | | \\
         /__|_|__\\
            Λ
      """
    ],
    fantasy: [
      """
              /\\
             /  \\
            /    \\
           / 🏰  \\
          /________\\
         /|   ||   |\\
        / |   ||   | \\
       /__|___||___|__\\
            ⚔️  🛡️
      """,
      """
              __
             /  \\
            | 🐉 |
             \\__/
            / || \\
           /  ||  \\
          /___||___\\
              /\\
             /  \\
      """,
      """
           .     .
          /|     |\\
         / | ⚔️ | \\
        /  |_____|  \\
       /___|     |___\\
           | 🧙 |
           |_____|
      """
    ],
    food: [
      """
            _______
           /       \\
          /  🍽️    \\
         |  ═══════  |
         | 🍖 🍗 🥗 |
         |___________|
            \\___/
      """,
      """
              ___
             (   )
            (     )
             (   )
              \\ /
               Y
              /|\\
             / | \\
      """,
      """
           .-------.
          /         \\
         |  ☕  🍰  |
         |_________|
          \\_______/
      """
    ],
    home: [
      """
                ___
               /   \\
              /     \\
             /  🏠   \\
            /_________\\
            |  |   |  |
            |  | 🚪|  |
            |__|___|__|
      """,
      """
              /\\
             /  \\
            /    \\
           /______\\
           | 🪟🪟 |
           |  ╔╗  |
           |  ║║  |
           |__╚╝__|
      """,
      """
            .---.
           /     \\
          /_______\\
          |░░░░░░░|
          |░ ♥️  ░|
          |░░░░░░░|
          '-------'
      """
    ],
    time: [
      """
              ___
             /   \\
            |  ⏰ |
            |  12 |
            |9  3|
            |  6  |
             \\___/
      """,
      """
           ╔═══════╗
           ║ ⌛    ║
           ║  \\ /  ║
           ║   X   ║
           ║  / \\  ║
           ║ ⌛    ║
           ╚═══════╝
      """,
      """
              .-.
             ( H )
              '-'
              /|\\
               |
              / \\
            📜  📜
      """
    ],
    love: [
      """
             ♥️  ♥️
            ♥️♥️♥️♥️
           ♥️♥️♥️♥️♥️
            ♥️♥️♥️♥️
             ♥️♥️♥️
              ♥️♥️
               ♥️
      """,
      """
           .---.  .---.
          /     \\/     \\
          |  ♥️    ♥️   |
           \\          /
            \\   ♥️   /
             \\     /
              \\   /
               \\ /
                V
      """
    ],
    animals: [
      """
             /\\_/\\
            ( o.o )
             > ^ <
            /|   |\\
           (_|   |_)
      """,
      """
                .---.
               /     \\
              | () () |
               \\  ^  /
                |||||
               /|||||\\
      """,
      """
                 __
               .'  '.
              /  🦉  \\
             |   ||   |
              \\ _||_ /
               '-..-'
      """
    ],
    weather: [
      """
               .-~~~-.
             .'       '.
            (  ☁️ ☁️  )
             '.     .'
               '---'
                /|\\
               / | \\
              ⛈️ ⛈️ ⛈️
      """,
      """
                 \\   |   /
               .-'-.☀️.-'-.
                 /   |   \\
              .'.  '.  .'.
             /   \\    /   \\
      """,
      """
              .---.
             /     \\
            |  ❄️  |
             \\     /
              '---'
            ❄️ ❄️ ❄️
      """
    ],
    celebration: [
      """
            🎉  ★  🎉
           ★  🎊  ★
          🎉 ★  ★ 🎉
           ★ 🎉🎉 ★
          🎊 ★  ★ 🎊
           ★  🎉  ★
            🎉  ★  🎉
      """,
      """
              ╔═══╗
              ║🎂║
              ╚═══╝
             🎁🎁🎁
            ★ ★ ★ ★
           ★ 🎈🎈 ★
            ★ ★ ★ ★
      """
    ],
    default: [
      """
          ╭─────────────╮
          │   ❦   ❦    │
          │      ◆      │
          │   ❦   ❦    │
          ╰─────────────╯
      """,
      """
           ═══════════
          ╔           ╗
          ║     ❦     ║
          ╚           ╝
           ═══════════
      """,
      """
           .・。.・゜✭・
          ・゜・。.   .・
          ✭    ❦    ✭
          ・゜・。.   .・
           .・。.・゜✭・
      """
    ]
  }

  # Decorative corner pieces
  @corners %{
    ornate: %{
      tl: "╔",
      tr: "╗",
      bl: "╚",
      br: "╝",
      h: "═",
      v: "║"
    },
    simple: %{
      tl: "+",
      tr: "+",
      bl: "+",
      br: "+",
      h: "-",
      v: "|"
    },
    round: %{
      tl: "╭",
      tr: "╮",
      bl: "╰",
      br: "╯",
      h: "─",
      v: "│"
    },
    double: %{
      tl: "╔",
      tr: "╗",
      bl: "╚",
      br: "╝",
      h: "═",
      v: "║"
    }
  }

  @doc """
  Gets a random art piece for the given theme.
  """
  def get_art(theme) do
    arts = Map.get(@art_library, theme, @art_library.default)
    Enum.random(arts)
  end

  @doc """
  Gets all art options for a theme.
  """
  def get_all_art(theme) do
    Map.get(@art_library, theme, @art_library.default)
  end

  @doc """
  Lists all available themes.
  """
  def themes do
    Map.keys(@art_library)
  end

  @doc """
  Creates a decorative frame around text.
  """
  def frame(text, opts \\ []) do
    style = Keyword.get(opts, :style, :ornate)
    padding = Keyword.get(opts, :padding, 2)

    corners = Map.get(@corners, style, @corners.simple)

    lines = String.split(text, "\n")
    max_width = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    width = max_width + (padding * 2)

    top = corners.tl <> String.duplicate(corners.h, width) <> corners.tr
    bottom = corners.bl <> String.duplicate(corners.h, width) <> corners.br

    middle = Enum.map(lines, fn line ->
      padded = String.pad_trailing(line, max_width)
      pad = String.duplicate(" ", padding)
      corners.v <> pad <> padded <> pad <> corners.v
    end)

    [top | middle] ++ [bottom]
    |> Enum.join("\n")
  end

  @doc """
  Creates a decorative divider.
  """
  def divider(style \\ :ornate, width \\ 50) do
    case style do
      :ornate -> "═" |> String.duplicate(width)
      :simple -> "-" |> String.duplicate(width)
      :dots -> "• " |> String.duplicate(div(width, 2))
      :wave -> "~" |> String.duplicate(width)
      :stars -> "★ ☆ " |> String.duplicate(div(width, 4))
      :vine -> "~*~" |> String.duplicate(div(width, 3))
      :celtic -> "─┼─" |> String.duplicate(div(width, 3))
      _ -> "-" |> String.duplicate(width)
    end
  end

  @doc """
  Creates a decorative section header.
  """
  def section_header(title, style \\ :ornate) do
    width = String.length(title) + 10

    case style do
      :ornate ->
        """
        ╔#{String.duplicate("═", width)}╗
        ║#{center(title, width)}║
        ╚#{String.duplicate("═", width)}╝
        """
      :simple ->
        """
        +#{String.duplicate("-", width)}+
        |#{center(title, width)}|
        +#{String.duplicate("-", width)}+
        """
      :medieval ->
        """
        ❦═══#{String.duplicate("═", width - 8)}═══❦
             #{title}
        ❦═══#{String.duplicate("═", width - 8)}═══❦
        """
      _ ->
        "=== #{title} ==="
    end
  end

  @doc """
  Generates AI-powered custom illustration.
  """
  def generate_custom(description, opts \\ []) do
    max_width = Keyword.get(opts, :max_width, 35)
    max_height = Keyword.get(opts, :max_height, 12)
    style = Keyword.get(opts, :style, "medieval woodcut")

    prompt = """
    Create ASCII art (#{max_width} chars wide, #{max_height} lines tall max).
    Style: #{style} / 8-bit pixel art
    Subject: #{String.slice(description, 0, 150)}

    Rules:
    - Use basic ASCII: / \\ | - _ = + * . o O @ # $ % ^ & ( ) [ ] { } < >
    - Can use these unicode: ═ ║ ╔ ╗ ╚ ╝ ╭ ╮ ╰ ╯ ● ○ ◆ ◇ ★ ☆ ♠ ♣ ♥ ♦
    - Keep it simple and recognizable
    - No explanation, just the art

    ASCII art:
    """

    case AiEngine.generate(prompt, max_tokens: 300) do
      {:ok, art} ->
        clean_art(art, max_width, max_height)
      _ ->
        get_art(:default)
    end
  end

  @doc """
  Creates a pixel-art style border decoration.
  """
  def pixel_border(width, height) do
    top = "█" <> String.duplicate("▀", width - 2) <> "█"
    bottom = "█" <> String.duplicate("▄", width - 2) <> "█"
    middle = "█" <> String.duplicate(" ", width - 2) <> "█"

    [top] ++
    List.duplicate(middle, height - 2) ++
    [bottom]
    |> Enum.join("\n")
  end

  @doc """
  Creates an illuminated initial letter (drop cap).
  """
  def illuminated_letter(letter) do
    upper = String.upcase(letter)

    case upper do
      "A" -> illuminated_a()
      "B" -> illuminated_b()
      "C" -> illuminated_c()
      "D" -> illuminated_d()
      "E" -> illuminated_e()
      "F" -> illuminated_f()
      "G" -> illuminated_g()
      "H" -> illuminated_h()
      "I" -> illuminated_i()
      "J" -> illuminated_j()
      "K" -> illuminated_k()
      "L" -> illuminated_l()
      "M" -> illuminated_m()
      "N" -> illuminated_n()
      "O" -> illuminated_o()
      "P" -> illuminated_p()
      "Q" -> illuminated_q()
      "R" -> illuminated_r()
      "S" -> illuminated_s()
      "T" -> illuminated_t()
      "U" -> illuminated_u()
      "V" -> illuminated_v()
      "W" -> illuminated_w()
      "X" -> illuminated_x()
      "Y" -> illuminated_y()
      "Z" -> illuminated_z()
      _ -> simple_letter(upper)
    end
  end

  # Private functions

  defp center(text, width) do
    text_len = String.length(text)
    if text_len >= width do
      text
    else
      padding = div(width - text_len, 2)
      String.duplicate(" ", padding) <> text <> String.duplicate(" ", width - padding - text_len)
    end
  end

  defp clean_art(art, max_width, max_height) do
    art
    |> String.trim()
    |> String.split("\n")
    |> Enum.take(max_height)
    |> Enum.map(&String.slice(&1, 0, max_width))
    |> Enum.join("\n")
  end

  defp simple_letter(letter) do
    """
    ╔═══╗
    ║ #{letter} ║
    ╚═══╝
    """
  end

  # Illuminated letters with decorative frames
  defp illuminated_a do
    """
    ╔═══════════╗
    ║ ❦     ❦  ║
    ║    /\\    ║
    ║   /  \\   ║
    ║  / ❦❦ \\  ║
    ║ /══════\\ ║
    ║/        \\║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_b do
    """
    ╔═══════════╗
    ║ ❦  ██▄ ❦ ║
    ║   █▀▀█   ║
    ║   █▄▄▀   ║
    ║   █▀▀█   ║
    ║   █▄▄█   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_c do
    """
    ╔═══════════╗
    ║ ❦ ▄██▄ ❦ ║
    ║  █▀      ║
    ║  █       ║
    ║  █▄      ║
    ║   ▀██▀   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_d do
    """
    ╔═══════════╗
    ║ ❦ ██▄  ❦ ║
    ║   █  █   ║
    ║   █   █  ║
    ║   █  █   ║
    ║   ██▀    ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_e do
    """
    ╔═══════════╗
    ║ ❦ ████ ❦ ║
    ║   █      ║
    ║   ███    ║
    ║   █      ║
    ║   ████   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_f do
    """
    ╔═══════════╗
    ║ ❦ ████ ❦ ║
    ║   █      ║
    ║   ███    ║
    ║   █      ║
    ║   █      ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_g do
    """
    ╔═══════════╗
    ║ ❦ ▄██▄ ❦ ║
    ║  █▀      ║
    ║  █  ██   ║
    ║  █   █   ║
    ║   ▀██▀   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_h do
    """
    ╔═══════════╗
    ║ ❦ █  █ ❦ ║
    ║   █  █   ║
    ║   ████   ║
    ║   █  █   ║
    ║   █  █   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_i do
    """
    ╔═══════════╗
    ║ ❦ ████ ❦ ║
    ║    ██    ║
    ║    ██    ║
    ║    ██    ║
    ║   ████   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_j do
    """
    ╔═══════════╗
    ║ ❦  ███ ❦ ║
    ║     █    ║
    ║     █    ║
    ║  █  █    ║
    ║   ██     ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_k do
    """
    ╔═══════════╗
    ║ ❦ █  █ ❦ ║
    ║   █ █    ║
    ║   ██     ║
    ║   █ █    ║
    ║   █  █   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_l do
    """
    ╔═══════════╗
    ║ ❦ █    ❦ ║
    ║   █      ║
    ║   █      ║
    ║   █      ║
    ║   ████   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_m do
    """
    ╔═══════════╗
    ║ ❦█▄  ▄█❦ ║
    ║  █ ▀▀ █  ║
    ║  █ ██ █  ║
    ║  █    █  ║
    ║  █    █  ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_n do
    """
    ╔═══════════╗
    ║ ❦ █▄  █❦ ║
    ║   █ █ █  ║
    ║   █  ██  ║
    ║   █   █  ║
    ║   █   █  ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_o do
    """
    ╔═══════════╗
    ║ ❦ ▄██▄ ❦ ║
    ║  █    █  ║
    ║  █    █  ║
    ║  █    █  ║
    ║   ▀██▀   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_p do
    """
    ╔═══════════╗
    ║ ❦ ███▄ ❦ ║
    ║   █   █  ║
    ║   ███▀   ║
    ║   █      ║
    ║   █      ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_q do
    """
    ╔═══════════╗
    ║ ❦ ▄██▄ ❦ ║
    ║  █    █  ║
    ║  █    █  ║
    ║  █  █ █  ║
    ║   ▀██▀█  ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_r do
    """
    ╔═══════════╗
    ║ ❦ ███▄ ❦ ║
    ║   █   █  ║
    ║   ███▀   ║
    ║   █  █   ║
    ║   █   █  ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_s do
    """
    ╔═══════════╗
    ║ ❦ ▄███ ❦ ║
    ║   █      ║
    ║    ██▄   ║
    ║      █   ║
    ║   ███▀   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_t do
    """
    ╔═══════════╗
    ║ ❦█████❦  ║
    ║    █     ║
    ║    █     ║
    ║    █     ║
    ║    █     ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_u do
    """
    ╔═══════════╗
    ║ ❦ █   █❦ ║
    ║   █   █  ║
    ║   █   █  ║
    ║   █   █  ║
    ║    ███   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_v do
    """
    ╔═══════════╗
    ║ ❦ █   █❦ ║
    ║   █   █  ║
    ║    █ █   ║
    ║    █ █   ║
    ║     █    ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_w do
    """
    ╔═══════════╗
    ║ ❦█    █❦ ║
    ║  █    █  ║
    ║  █ ██ █  ║
    ║  █ ▄▄ █  ║
    ║  █▀  ▀█  ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_x do
    """
    ╔═══════════╗
    ║ ❦ █   █❦ ║
    ║    █ █   ║
    ║     █    ║
    ║    █ █   ║
    ║   █   █  ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_y do
    """
    ╔═══════════╗
    ║ ❦ █   █❦ ║
    ║    █ █   ║
    ║     █    ║
    ║     █    ║
    ║     █    ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end

  defp illuminated_z do
    """
    ╔═══════════╗
    ║ ❦ ████ ❦ ║
    ║     █    ║
    ║    █     ║
    ║   █      ║
    ║   ████   ║
    ║ ❦     ❦  ║
    ╚═══════════╝
    """
  end
end
