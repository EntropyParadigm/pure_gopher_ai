defmodule PureGopherAi.AnsiArt do
  @moduledoc """
  ANSI color art library for terminals that support escape codes.

  Provides 16-color ASCII art for phlog posts and decorations.
  Falls back gracefully for terminals that don't support ANSI.

  ANSI Color Codes (16 colors):
  - 30-37: Foreground (black, red, green, yellow, blue, magenta, cyan, white)
  - 40-47: Background
  - 90-97: Bright foreground
  - 100-107: Bright background
  - 0: Reset, 1: Bold, 2: Dim, 4: Underline, 5: Blink, 7: Reverse
  """

  # ANSI escape sequences
  @reset "\e[0m"
  @bold "\e[1m"

  # Foreground colors
  @black "\e[30m"
  @red "\e[31m"
  @green "\e[32m"
  @yellow "\e[33m"
  @blue "\e[34m"
  @magenta "\e[35m"
  @cyan "\e[36m"
  @white "\e[37m"

  # Bright foreground colors
  @bright_black "\e[90m"
  @bright_red "\e[91m"
  @bright_green "\e[92m"
  @bright_yellow "\e[93m"
  @bright_blue "\e[94m"
  @bright_magenta "\e[95m"
  @bright_cyan "\e[96m"
  @bright_white "\e[97m"

  # Background colors (available for future use)
  # @bg_black "\e[40m"
  # @bg_red "\e[41m"
  # @bg_green "\e[42m"
  # @bg_yellow "\e[43m"
  # @bg_blue "\e[44m"
  # @bg_magenta "\e[45m"
  # @bg_cyan "\e[46m"
  # @bg_white "\e[47m"

  # Themed color art library
  @color_art %{
    technology: [
      """
      #{@cyan}    ┌──────────────────┐#{@reset}
      #{@cyan}    │#{@bright_blue}  ╔═══════════╗  #{@cyan}│#{@reset}
      #{@cyan}    │#{@bright_blue}  ║#{@bright_green} 0#{@bright_cyan}1#{@bright_green}0#{@bright_cyan}1#{@bright_green}0#{@bright_cyan}1#{@bright_green}0 #{@bright_blue}║  #{@cyan}│#{@reset}
      #{@cyan}    │#{@bright_blue}  ║#{@bright_cyan} 1#{@bright_green}0#{@bright_cyan}1#{@bright_green}0#{@bright_cyan}1#{@bright_green}0#{@bright_cyan}1 #{@bright_blue}║  #{@cyan}│#{@reset}
      #{@cyan}    │#{@bright_blue}  ╚═══════════╝  #{@cyan}│#{@reset}
      #{@cyan}    │#{@white}   [_________]   #{@cyan}│#{@reset}
      #{@cyan}    └──────────────────┘#{@reset}
      """,
      """
      #{@bright_cyan}        .---.#{@reset}
      #{@bright_cyan}       /     \\#{@reset}
      #{@bright_cyan}       \\#{@bright_yellow}.@#{@reset}#{@bright_cyan}-#{@bright_yellow}@#{@reset}#{@bright_cyan}./#{@reset}
      #{@bright_cyan}       /`\\_/`\\#{@reset}
      #{@cyan}      //#{@bright_white}  _  #{@cyan}\\\\#{@reset}
      #{@cyan}     | \\     / |#{@reset}
      #{@blue}      \\|  |  |/#{@reset}
      #{@blue}       |__|__|#{@reset}
      #{@bright_black}      /___|___\\#{@reset}
      """
    ],
    nature: [
      """
      #{@bright_yellow}              .  *  .#{@reset}
      #{@bright_yellow}           *#{@reset}    #{@green}🌲#{@reset}    #{@bright_yellow}*#{@reset}
      #{@bright_yellow}          .#{@reset}   #{@green}🌲#{@reset}  #{@green}🌲#{@reset}   #{@bright_yellow}.#{@reset}
      #{@bright_yellow}         *#{@reset}  #{@green}🌲🌲#{@reset}  #{@green}🌲🌲#{@reset}  #{@bright_yellow}*#{@reset}
      #{@bright_yellow}        .#{@reset} #{@green}🌲🌲🌲🌲🌲🌲🌲#{@reset} #{@bright_yellow}.#{@reset}
      #{@yellow}       ════════════════════#{@reset}
      #{@cyan}           ~~~#{@reset}  #{@yellow}🦌#{@reset}  #{@cyan}~~~#{@reset}
      """,
      """
      #{@green}               ( )#{@reset}
      #{@bright_green}              (   )#{@reset}
      #{@green}               ) (#{@reset}
      #{@yellow}              /   \\#{@reset}
      #{@yellow}             /     \\#{@reset}
      #{@yellow}            /_______\\#{@reset}
      #{@yellow}               │ │#{@reset}
      #{@cyan}           ~~~~│_│~~~~#{@reset}
      """
    ],
    adventure: [
      """
      #{@white}              /\\#{@reset}
      #{@bright_white}             /  \\#{@reset}
      #{@bright_white}            /#{@bright_cyan} ⛰️ #{@bright_white}\\#{@reset}
      #{@white}           /      \\#{@reset}
      #{@bright_black}          /   /\\   \\#{@reset}
      #{@bright_black}         /   /  \\   \\#{@reset}
      #{@bright_black}        /___/____\\___\\#{@reset}
      #{@yellow}            🚶#{@bright_yellow}➡️#{@reset}
      #{@cyan}       ~~~~~~~~~~~~~~~#{@reset}
      """,
      """
      #{@yellow}           ___________#{@reset}
      #{@yellow}          /           \\#{@reset}
      #{@yellow}         /  #{@bright_red}X marks#{@yellow}    \\#{@reset}
      #{@yellow}        /   #{@bright_red}the spot#{@yellow}    \\#{@reset}
      #{@yellow}       /      #{@bright_red}╳#{@yellow}          \\#{@reset}
      #{@yellow}      /___________________|#{@reset}
      #{@yellow}          /         \\#{@reset}
      #{@yellow}         /           \\#{@reset}
      """
    ],
    space: [
      """
      #{@bright_white}        *#{@reset}  #{@bright_cyan}.#{@reset}  #{@bright_yellow}★#{@reset}  #{@bright_cyan}.#{@reset}  #{@bright_white}*#{@reset}
      #{@bright_cyan}      .#{@reset}    #{@bright_yellow}🌙#{@reset}     #{@bright_cyan}.#{@reset}
      #{@bright_yellow}          ★#{@reset}       #{@bright_yellow}★#{@reset}
      #{@bright_red}             🚀#{@reset}
      #{@bright_cyan}        .#{@reset}  #{@bright_yellow}★#{@reset}    #{@bright_cyan}.#{@reset}    #{@bright_yellow}★#{@reset}
      #{@bright_cyan}          .#{@reset}   #{@bright_white}*#{@reset}   #{@bright_cyan}.#{@reset}
      #{@bright_white}        *#{@reset}   #{@bright_cyan}.#{@reset}  #{@bright_yellow}★#{@reset}  #{@bright_cyan}.#{@reset}   #{@bright_white}*#{@reset}
      """,
      """
      #{@bright_white}             .#{@reset}  #{@bright_white}*#{@reset}
      #{@bright_white}          *#{@reset}       #{@bright_cyan}.#{@reset}
      #{@bright_cyan}        .#{@reset}    #{@bright_yellow}🪐#{@reset}      #{@bright_white}*#{@reset}
      #{@bright_white}          *#{@reset}       #{@bright_cyan}.#{@reset}
      #{@bright_cyan}        .#{@reset}     #{@bright_yellow}★#{@reset}     #{@bright_cyan}.#{@reset}
      #{@bright_blue}          🌍#{@reset}
      #{@bright_white}        *#{@reset}   #{@bright_cyan}.#{@reset}   #{@bright_white}*#{@reset}
      """
    ],
    fantasy: [
      """
      #{@bright_white}             /\\#{@reset}
      #{@white}            /  \\#{@reset}
      #{@white}           /    \\#{@reset}
      #{@yellow}          / #{@bright_yellow}🏰#{@yellow}  \\#{@reset}
      #{@yellow}         /________\\#{@reset}
      #{@bright_black}        /|   ||   |\\#{@reset}
      #{@bright_black}       / |   ||   | \\#{@reset}
      #{@bright_black}      /__|___||___|__\\#{@reset}
      #{@cyan}           ⚔️#{@reset}  #{@bright_blue}🛡️#{@reset}
      """,
      """
      #{@bright_red}             __#{@reset}
      #{@bright_red}            /  \\#{@reset}
      #{@bright_red}           | #{@bright_yellow}🐉#{@bright_red} |#{@reset}
      #{@bright_red}            \\__/#{@reset}
      #{@red}           / || \\#{@reset}
      #{@red}          /  ||  \\#{@reset}
      #{@red}         /___||___\\#{@reset}
      #{@bright_yellow}             /\\#{@reset}
      #{@yellow}            /  \\#{@reset}
      """
    ],
    knowledge: [
      """
      #{@yellow}           ____________#{@reset}
      #{@yellow}          /            \\#{@reset}
      #{@yellow}         /  #{@bright_blue}📚 📖 📚#{@yellow}   \\#{@reset}
      #{@yellow}        /________________\\#{@reset}
      #{@bright_yellow}        |  ═══════════  |#{@reset}
      #{@bright_white}        |  #{@bold}KNOWLEDGE#{@reset}#{@bright_white}    |#{@reset}
      #{@bright_white}        |  #{@bold}IS POWER#{@reset}#{@bright_white}     |#{@reset}
      #{@bright_yellow}        |  ═══════════  |#{@reset}
      #{@yellow}        |________________|#{@reset}
      """,
      """
      #{@yellow}            _______#{@reset}
      #{@yellow}           /      //#{@reset}
      #{@yellow}          /      //#{@reset}
      #{@yellow}         /______//#{@reset}
      #{@bright_blue}         |  📖  |#{@reset}
      #{@yellow}         |______|#{@reset}
      #{@yellow}         | .  . |#{@reset}
      #{@yellow}         |______|#{@reset}
      """
    ],
    music: [
      """
      #{@bright_magenta}          ♪#{@reset} #{@bright_cyan}♫#{@reset} #{@bright_yellow}♪#{@reset} #{@bright_green}♫#{@reset} #{@bright_blue}♪#{@reset}
      #{@white}         ┌─────────┐#{@reset}
      #{@white}         │#{@bright_magenta} ♩#{@reset}  #{@bright_cyan}♬#{@reset}  #{@bright_magenta}♩#{@reset} #{@white}│#{@reset}
      #{@white}         │ ═══════ │#{@reset}
      #{@white}         │  #{@bright_yellow}🎵#{@reset}#{@white}     │#{@reset}
      #{@white}         │ ═══════ │#{@reset}
      #{@white}         └─────────┘#{@reset}
      #{@bright_cyan}          ♫#{@reset} #{@bright_yellow}♪#{@reset} #{@bright_green}♫#{@reset} #{@bright_magenta}♪#{@reset} #{@bright_blue}♫#{@reset}
      """,
      """
      #{@bright_yellow}             ___#{@reset}
      #{@yellow}            /   \\#{@reset}
      #{@yellow}           |  O  |#{@reset}
      #{@yellow}           |     |#{@reset}
      #{@yellow}            \\___/#{@reset}
      #{@bright_black}              |#{@reset}
      #{@bright_black}              |#{@reset}
      #{@bright_black}             /|\\#{@reset}
      #{@bright_black}            / | \\#{@reset}
      """
    ],
    love: [
      """
      #{@bright_red}            ♥️#{@reset}  #{@bright_red}♥️#{@reset}
      #{@red}           ♥️♥️♥️♥️#{@reset}
      #{@bright_red}          ♥️♥️♥️♥️♥️#{@reset}
      #{@red}           ♥️♥️♥️♥️#{@reset}
      #{@bright_red}            ♥️♥️♥️#{@reset}
      #{@red}             ♥️♥️#{@reset}
      #{@bright_red}              ♥️#{@reset}
      """,
      """
      #{@bright_red}          .---.  .---.#{@reset}
      #{@red}         /     \\/     \\#{@reset}
      #{@bright_red}         |  #{@bright_magenta}♥️#{@reset}#{@bright_red}    #{@bright_magenta}♥️#{@reset}#{@bright_red}   |#{@reset}
      #{@red}          \\          /#{@reset}
      #{@bright_red}           \\   #{@bright_magenta}♥️#{@reset}#{@bright_red}   /#{@reset}
      #{@red}            \\     /#{@reset}
      #{@bright_red}             \\   /#{@reset}
      #{@red}              \\ /#{@reset}
      #{@bright_red}               V#{@reset}
      """
    ],
    fire: [
      """
      #{@bright_yellow}            (#{@reset}
      #{@bright_yellow}           ) )#{@reset}
      #{@yellow}          ( (#{@reset}
      #{@bright_red}           ) )#{@reset}
      #{@red}        ,-----.#{@reset}
      #{@bright_red}       /#{@bright_yellow}~#{@red}\\#{@bright_yellow}~#{@red}\\#{@bright_yellow}~#{@red}\\#{@reset}
      #{@red}      / #{@bright_yellow}~#{@reset}#{@red} #{@bright_yellow}~#{@reset}#{@red} #{@bright_yellow}~#{@red} \\#{@reset}
      #{@bright_red}     (#{@yellow}~#{@bright_yellow}~~~#{@yellow}~#{@bright_red})#{@reset}
      #{@red}      \\#{@bright_yellow}~~~~~#{@red}/#{@reset}
      #{@bright_black}       \\___/#{@reset}
      """,
      """
      #{@bright_yellow}         )  (#{@reset}
      #{@yellow}        (    )#{@reset}
      #{@bright_red}         )  (#{@reset}
      #{@red}        /    \\#{@reset}
      #{@bright_red}       / #{@bright_yellow})(#{@bright_red} \\#{@reset}
      #{@red}      /  #{@yellow})(#{@red}  \\#{@reset}
      #{@bright_red}     ( #{@bright_yellow})()(#{@bright_red} )#{@reset}
      #{@red}      \\#{@yellow}~~~~#{@red}/#{@reset}
      #{@bright_black}       \\__/#{@reset}
      """
    ],
    water: [
      """
      #{@bright_cyan}      ~~~~~~~~~~~~~~~#{@reset}
      #{@cyan}     ~~~~~~~~~~~~~~~~~#{@reset}
      #{@bright_blue}    ~~~~~~~~~~~~~~~~~~~#{@reset}
      #{@blue}   ~~~~~~~~~~~~~~~~~~~~~#{@reset}
      #{@bright_cyan}    ~~~~~~~~~~~~~~~~~~~#{@reset}
      #{@cyan}     ~~~~~~~~~~~~~~~~~#{@reset}
      #{@bright_blue}      ~~~~~~~~~~~~~~~#{@reset}
      """,
      """
      #{@bright_cyan}          .---.#{@reset}
      #{@cyan}         /     \\#{@reset}
      #{@bright_blue}        |  #{@bright_cyan}~~~#{@bright_blue}  |#{@reset}
      #{@blue}        | #{@cyan}~~~~~#{@blue} |#{@reset}
      #{@bright_blue}        |  #{@bright_cyan}~~~#{@bright_blue}  |#{@reset}
      #{@cyan}         \\     /#{@reset}
      #{@bright_cyan}          '---'#{@reset}
      """
    ],
    celebration: [
      """
      #{@bright_yellow}           🎉#{@reset}  #{@bright_white}★#{@reset}  #{@bright_magenta}🎉#{@reset}
      #{@bright_white}          ★#{@reset}  #{@bright_cyan}🎊#{@reset}  #{@bright_white}★#{@reset}
      #{@bright_yellow}         🎉#{@reset} #{@bright_white}★#{@reset}  #{@bright_white}★#{@reset} #{@bright_magenta}🎉#{@reset}
      #{@bright_white}          ★#{@reset} #{@bright_yellow}🎉🎉#{@reset} #{@bright_white}★#{@reset}
      #{@bright_cyan}         🎊#{@reset} #{@bright_white}★#{@reset}  #{@bright_white}★#{@reset} #{@bright_cyan}🎊#{@reset}
      #{@bright_white}          ★#{@reset}  #{@bright_magenta}🎉#{@reset}  #{@bright_white}★#{@reset}
      #{@bright_yellow}           🎉#{@reset}  #{@bright_white}★#{@reset}  #{@bright_magenta}🎉#{@reset}
      """,
      """
      #{@yellow}             ╔═══╗#{@reset}
      #{@yellow}             ║#{@bright_yellow}🎂#{@yellow}║#{@reset}
      #{@yellow}             ╚═══╝#{@reset}
      #{@bright_magenta}            🎁#{@bright_cyan}🎁#{@bright_green}🎁#{@reset}
      #{@bright_white}           ★ ★ ★ ★#{@reset}
      #{@bright_red}          ★#{@reset} #{@bright_blue}🎈🎈#{@reset} #{@bright_red}★#{@reset}
      #{@bright_white}           ★ ★ ★ ★#{@reset}
      """
    ],
    weather: [
      """
      #{@bright_white}              .~~~.#{@reset}
      #{@white}            .'     '.#{@reset}
      #{@bright_white}           (  #{@bright_cyan}☁️#{@reset} #{@bright_cyan}☁️#{@bright_white}  )#{@reset}
      #{@white}            '.     .'#{@reset}
      #{@bright_white}              '---'#{@reset}
      #{@bright_cyan}               /|\\#{@reset}
      #{@cyan}              / | \\#{@reset}
      #{@bright_blue}             ⛈️#{@reset} #{@bright_blue}⛈️#{@reset} #{@bright_blue}⛈️#{@reset}
      """,
      """
      #{@bright_yellow}                \\   |   /#{@reset}
      #{@yellow}              .-'-. #{@bright_yellow}☀️#{@yellow} .-'-.#{@reset}
      #{@bright_yellow}                /   |   \\#{@reset}
      #{@bright_white}             .'.  '.  .'.#{@reset}
      #{@white}            /   \\    /   \\#{@reset}
      """
    ],
    default: [
      """
      #{@cyan}         ╭─────────────╮#{@reset}
      #{@cyan}         │#{@reset}   #{@bright_magenta}❦#{@reset}   #{@bright_magenta}❦#{@reset}    #{@cyan}│#{@reset}
      #{@cyan}         │#{@reset}      #{@bright_yellow}◆#{@reset}      #{@cyan}│#{@reset}
      #{@cyan}         │#{@reset}   #{@bright_magenta}❦#{@reset}   #{@bright_magenta}❦#{@reset}    #{@cyan}│#{@reset}
      #{@cyan}         ╰─────────────╯#{@reset}
      """,
      """
      #{@bright_white}          .・。.・゜#{@bright_cyan}✭#{@bright_white}・#{@reset}
      #{@bright_white}         ・゜・。.   .・#{@reset}
      #{@bright_cyan}         ✭#{@reset}    #{@bright_magenta}❦#{@reset}    #{@bright_cyan}✭#{@reset}
      #{@bright_white}         ・゜・。.   .・#{@reset}
      #{@bright_white}          .・。.・゜#{@bright_cyan}✭#{@bright_white}・#{@reset}
      """
    ]
  }

  # Colorful illuminated drop caps
  @color_drop_caps %{
    "A" => """
    #{@bright_yellow}╔═══════════╗#{@reset}
    #{@bright_yellow}║#{@reset} #{@bright_red}❦#{@reset}     #{@bright_red}❦#{@reset}  #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}    #{@bright_blue}/\\#{@reset}    #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}   #{@bright_blue}/  \\#{@reset}   #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}  #{@bright_cyan}/════\\#{@reset}  #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset} #{@bright_cyan}/      \\#{@reset} #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset} #{@bright_red}❦#{@reset}     #{@bright_red}❦#{@reset}  #{@bright_yellow}║#{@reset}
    #{@bright_yellow}╚═══════════╝#{@reset}
    """,
    "B" => """
    #{@bright_yellow}╔═══════════╗#{@reset}
    #{@bright_yellow}║#{@reset} #{@bright_red}❦#{@reset} #{@bright_blue}██▄#{@reset} #{@bright_red}❦#{@reset} #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}   #{@bright_blue}█▀▀█#{@reset}   #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}   #{@bright_cyan}█▄▄▀#{@reset}   #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}   #{@bright_blue}█▀▀█#{@reset}   #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}   #{@bright_cyan}█▄▄█#{@reset}   #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset} #{@bright_red}❦#{@reset}     #{@bright_red}❦#{@reset}  #{@bright_yellow}║#{@reset}
    #{@bright_yellow}╚═══════════╝#{@reset}
    """,
    "C" => """
    #{@bright_yellow}╔═══════════╗#{@reset}
    #{@bright_yellow}║#{@reset} #{@bright_red}❦#{@reset} #{@bright_blue}▄██▄#{@reset} #{@bright_red}❦#{@reset} #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}  #{@bright_cyan}█▀#{@reset}      #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}  #{@bright_blue}█#{@reset}       #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}  #{@bright_cyan}█▄#{@reset}      #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset}   #{@bright_blue}▀██▀#{@reset}   #{@bright_yellow}║#{@reset}
    #{@bright_yellow}║#{@reset} #{@bright_red}❦#{@reset}     #{@bright_red}❦#{@reset}  #{@bright_yellow}║#{@reset}
    #{@bright_yellow}╚═══════════╝#{@reset}
    """
  }

  # Colorful borders
  @color_borders %{
    rainbow: String.duplicate("#{@red}═#{@yellow}═#{@green}═#{@cyan}═#{@blue}═#{@magenta}═", 8) <> @reset,
    fire: String.duplicate("#{@bright_red}~#{@bright_yellow}*#{@red}~#{@yellow}*", 12) <> @reset,
    ocean: String.duplicate("#{@bright_cyan}~#{@cyan}~#{@blue}~#{@bright_blue}~", 12) <> @reset,
    forest: String.duplicate("#{@green}*#{@bright_green}~#{@green}*#{@bright_green}~", 12) <> @reset,
    gold: String.duplicate("#{@bright_yellow}═#{@yellow}╪#{@bright_yellow}═#{@yellow}╪", 12) <> @reset,
    magic: String.duplicate("#{@bright_magenta}✦#{@magenta}─#{@bright_cyan}✦#{@cyan}─", 12) <> @reset
  }

  @doc """
  Gets a random color art piece for the given theme.
  """
  def get_art(theme) do
    arts = Map.get(@color_art, theme, @color_art.default)
    Enum.random(arts)
  end

  @doc """
  Gets all color art options for a theme.
  """
  def get_all_art(theme) do
    Map.get(@color_art, theme, @color_art.default)
  end

  @doc """
  Lists all available themes.
  """
  def themes do
    Map.keys(@color_art)
  end

  @doc """
  Gets a colorful illuminated drop cap.
  """
  def get_drop_cap(letter) do
    upper = String.upcase(letter)
    Map.get(@color_drop_caps, upper, default_color_cap(upper))
  end

  @doc """
  Gets a colorful border.
  """
  def get_border(style \\ :rainbow) do
    Map.get(@color_borders, style, @color_borders.rainbow)
  end

  @doc """
  Lists available border styles.
  """
  def border_styles do
    Map.keys(@color_borders)
  end

  @doc """
  Creates a colorful divider line.
  """
  def divider(style \\ :rainbow, width \\ 50) do
    case style do
      :rainbow ->
        colors = [@red, @yellow, @green, @cyan, @blue, @magenta]
        1..width
        |> Enum.map(fn i -> Enum.at(colors, rem(i, 6)) <> "═" end)
        |> Enum.join()
        |> Kernel.<>(@reset)

      :fire ->
        1..width
        |> Enum.map(fn i ->
          if rem(i, 2) == 0, do: @bright_yellow <> "~", else: @bright_red <> "*"
        end)
        |> Enum.join()
        |> Kernel.<>(@reset)

      :ocean ->
        1..width
        |> Enum.map(fn i ->
          case rem(i, 4) do
            0 -> @bright_cyan <> "~"
            1 -> @cyan <> "~"
            2 -> @blue <> "~"
            3 -> @bright_blue <> "~"
          end
        end)
        |> Enum.join()
        |> Kernel.<>(@reset)

      :forest ->
        1..width
        |> Enum.map(fn i ->
          if rem(i, 2) == 0, do: @bright_green <> "🌿", else: @green <> "~"
        end)
        |> Enum.join()
        |> Kernel.<>(@reset)

      _ ->
        @bright_cyan <> String.duplicate("─", width) <> @reset
    end
  end

  @doc """
  Colorizes plain text with a theme color.
  """
  def colorize(text, color) do
    color_code = case color do
      :red -> @red
      :bright_red -> @bright_red
      :green -> @green
      :bright_green -> @bright_green
      :yellow -> @yellow
      :bright_yellow -> @bright_yellow
      :blue -> @blue
      :bright_blue -> @bright_blue
      :magenta -> @magenta
      :bright_magenta -> @bright_magenta
      :cyan -> @cyan
      :bright_cyan -> @bright_cyan
      :white -> @white
      :bright_white -> @bright_white
      :black -> @black
      :bright_black -> @bright_black
      _ -> ""
    end

    color_code <> text <> @reset
  end

  @doc """
  Creates a colorful framed box around text.
  """
  def color_frame(text, opts \\ []) do
    border_color = Keyword.get(opts, :border_color, :bright_yellow)
    text_color = Keyword.get(opts, :text_color, :white)
    padding = Keyword.get(opts, :padding, 2)

    bc = get_color_code(border_color)
    tc = get_color_code(text_color)

    lines = String.split(text, "\n")
    max_width = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    width = max_width + (padding * 2)

    top = bc <> "╔" <> String.duplicate("═", width) <> "╗" <> @reset
    bottom = bc <> "╚" <> String.duplicate("═", width) <> "╝" <> @reset

    middle = Enum.map(lines, fn line ->
      padded = String.pad_trailing(line, max_width)
      pad = String.duplicate(" ", padding)
      bc <> "║" <> @reset <> pad <> tc <> padded <> @reset <> pad <> bc <> "║" <> @reset
    end)

    [top | middle] ++ [bottom]
    |> Enum.join("\n")
  end

  @doc """
  Strips ANSI codes from text (for fallback to plain).
  """
  def strip_ansi(text) do
    Regex.replace(~r/\e\[[0-9;]*m/, text, "")
  end

  @doc """
  Checks if text contains ANSI codes.
  """
  def has_ansi?(text) do
    String.contains?(text, "\e[")
  end

  # Private functions

  defp default_color_cap(letter) do
    """
    #{@bright_yellow}╔═══╗#{@reset}
    #{@bright_yellow}║#{@reset} #{@bright_cyan}#{letter}#{@reset} #{@bright_yellow}║#{@reset}
    #{@bright_yellow}╚═══╝#{@reset}
    """
  end

  defp get_color_code(color) do
    case color do
      :red -> @red
      :bright_red -> @bright_red
      :green -> @green
      :bright_green -> @bright_green
      :yellow -> @yellow
      :bright_yellow -> @bright_yellow
      :blue -> @blue
      :bright_blue -> @bright_blue
      :magenta -> @magenta
      :bright_magenta -> @bright_magenta
      :cyan -> @cyan
      :bright_cyan -> @bright_cyan
      :white -> @white
      :bright_white -> @bright_white
      :black -> @black
      :bright_black -> @bright_black
      _ -> ""
    end
  end
end
