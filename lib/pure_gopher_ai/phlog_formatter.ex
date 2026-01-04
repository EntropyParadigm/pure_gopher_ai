defmodule PureGopherAi.PhlogFormatter do
  @moduledoc """
  AI-powered phlog content formatter.

  Converts Markdown/plain text to Gopher format with creative
  ASCII art elements inspired by medieval illuminated manuscripts.

  Features:
  - Markdown to Gopher format conversion
  - URL/link auto-detection and conversion
  - Decorative ASCII art headers
  - AI-generated thematic illustrations
  - Illuminated drop caps (decorative first letters)
  - Medieval-style borders and dividers
  - Section ornaments and flourishes
  """

  alias PureGopherAi.AiEngine
  alias PureGopherAi.PhlogArt
  alias PureGopherAi.AnsiArt

  # Common theme keywords for art generation
  @theme_keywords %{
    technology: ~w(computer code software programming tech digital cyber internet web app api server),
    nature: ~w(tree forest mountain river ocean sea sky sun moon star flower garden plant),
    adventure: ~w(journey quest travel explore discover adventure path road map treasure),
    knowledge: ~w(book learn study read write wisdom knowledge library school university),
    music: ~w(music song melody rhythm note instrument guitar piano drum),
    food: ~w(food cook recipe kitchen meal dinner lunch breakfast eat drink),
    home: ~w(home house room door window family),
    space: ~w(space rocket planet star galaxy universe cosmic astronaut),
    fantasy: ~w(magic wizard dragon castle knight sword shield quest),
    time: ~w(time clock watch hour minute second day year history future past)
  }

  # Note: Illuminated drop caps are now provided by PhlogArt module

  # Decorative borders and dividers
  @borders %{
    simple: "═══════════════════════════════════════════════════════════",
    ornate: "╔═══════════════════════════════════════════════════════════╗",
    vine: "~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~",
    celtic: "┼──────────────────────────────────────────────────────────┼",
    wave: "~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~^~",
    dots: "• • • • • • • • • • • • • • • • • • • • • • • • • • • • • •",
    stars: "★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★ ☆ ★",
    diamond: "◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇─◇"
  }

  # Section ornaments
  @ornaments %{
    flourish_left: "❧",
    flourish_right: "❦",
    leaf: "❦",
    flower: "✿",
    star: "✦",
    cross: "✠",
    heart: "♥",
    diamond: "◆",
    club: "♣",
    spade: "♠"
  }

  # Thematic ASCII art templates
  @theme_art %{
    technology: """
        ┌──────────────┐
        │  ╔═══════╗   │
        │  ║ 01010 ║   │
        │  ║ 10101 ║   │
        │  ╚═══════╝   │
        │  [_______]   │
        └──────────────┘
    """,
    nature: """
           .  *  .
        .    🌲    .
       .   🌲  🌲   .
      . 🌲  🌲  🌲  .
     ════════════════
    """,
    adventure: """
          ⛰️
        ⛰️  ⛰️
       ~~~~~~~~
      🚶 ─────→
    """,
    knowledge: """
        ___________
       /          /|
      /  📖     / |
     /__________/  |
     |          |  /
     |__________|/
    """,
    music: """
       ♪ ♫ ♪ ♫
      ┌─────────┐
      │ ♩  ♬  ♩ │
      │  🎵     │
      └─────────┘
    """,
    space: """
        *  .  ★
      .   🌙   .
        ★   .
       .  *  .
      ★   .   *
    """,
    fantasy: """
          /\\
         /  \\
        /    \\
       /  ⚔️  \\
      /________\\
    """,
    default: """
      ╭─────────╮
      │  ❦  ❦  │
      │    ◆    │
      │  ❦  ❦  │
      ╰─────────╯
    """
  }

  @doc """
  Formats a phlog post with Gopher conversion and decorative elements.

  Options:
  - `:host` - Gopher host for links
  - `:port` - Gopher port for links
  - `:style` - Visual style (:minimal, :ornate, :medieval) - default :medieval
  - `:drop_cap` - Enable illuminated drop cap (default: true)
  - `:illustrations` - Enable AI-generated ASCII art (default: true)
  - `:borders` - Border style (:simple, :ornate, :vine, :celtic, etc.)
  - `:color` - Enable ANSI 16-color output for terminals that support it (default: false)
  """
  def format(title, body, opts \\ []) do
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 70)
    style = Keyword.get(opts, :style, :medieval)
    enable_drop_cap = Keyword.get(opts, :drop_cap, true)
    enable_illustrations = Keyword.get(opts, :illustrations, true)
    border_style = Keyword.get(opts, :borders, :ornate)
    enable_color = Keyword.get(opts, :color, false)

    # Detect theme from content
    theme = detect_theme(title <> " " <> body)

    # Build the formatted content
    lines = []

    # Add decorative header
    lines = lines ++ format_header(title, style, border_style, theme, enable_color)

    # Add thematic illustration if enabled
    lines = if enable_illustrations do
      lines ++ format_illustration(theme, enable_color)
    else
      lines
    end

    # Format body with drop cap and Gopher conversion
    formatted_body = format_body(body, host, port, enable_drop_cap, style, enable_color)
    lines = lines ++ formatted_body

    # Add decorative footer
    lines = lines ++ format_footer(style, border_style, enable_color)

    Enum.join(lines, "\n")
  end

  @doc """
  Formats content for preview (returns structured data).
  """
  def preview(title, body, opts \\ []) do
    formatted = format(title, body, opts)
    theme = detect_theme(title <> " " <> body)

    %{
      formatted: formatted,
      theme: theme,
      word_count: body |> String.split() |> length(),
      line_count: formatted |> String.split("\n") |> length(),
      has_links: String.contains?(body, "://") or String.contains?(body, "]("),
      has_images: String.contains?(body, "![")
    }
  end

  @doc """
  Generates a thematic ASCII art illustration using AI.
  """
  def generate_illustration(content, opts \\ []) do
    style = Keyword.get(opts, :style, :simple)
    max_width = Keyword.get(opts, :max_width, 40)
    max_height = Keyword.get(opts, :max_height, 10)

    prompt = """
    Create a simple ASCII art illustration (max #{max_width} chars wide, #{max_height} lines tall)
    that represents this content. Use only basic ASCII characters (no unicode).
    Style: #{style} (like a medieval woodcut illustration or 8-bit pixel art)

    Content summary: #{String.slice(content, 0, 200)}

    Output ONLY the ASCII art, no explanation:
    """

    case AiEngine.generate(prompt, max_tokens: 200) do
      {:ok, art} ->
        # Clean up and constrain the art
        art
        |> String.trim()
        |> String.split("\n")
        |> Enum.take(max_height)
        |> Enum.map(&String.slice(&1, 0, max_width))
        |> Enum.join("\n")
      _ ->
        # Fallback to theme-based art
        theme = detect_theme(content)
        Map.get(@theme_art, theme, @theme_art.default)
    end
  end

  @doc """
  Converts Markdown-style content to Gopher format.
  """
  def markdown_to_gopher(text, host, port) do
    text
    |> convert_headers()
    |> convert_links(host, port)
    |> convert_images(host, port)
    |> convert_code_blocks()
    |> convert_lists()
    |> convert_emphasis()
    |> convert_blockquotes()
    |> auto_detect_urls(host, port)
  end

  @doc """
  Creates an illuminated drop cap for the first letter.
  Supports optional ANSI color for terminals that support it.
  """
  def create_drop_cap(text, enable_color \\ false) do
    case String.first(text) do
      nil -> {"", text}
      first_char ->
        rest = String.slice(text, 1..-1//1)
        # Use AnsiArt for color, PhlogArt for plain ASCII
        art = if enable_color do
          AnsiArt.get_drop_cap(first_char)
        else
          PhlogArt.illuminated_letter(first_char)
        end
        {art, rest}
    end
  end

  @doc """
  Returns available border styles.
  """
  def border_styles, do: Map.keys(@borders)

  @doc """
  Returns available ornaments.
  """
  def ornaments, do: @ornaments

  # Private functions

  defp detect_theme(content) do
    content_lower = String.downcase(content)
    words = String.split(content_lower, ~r/\W+/)

    # Count matches for each theme
    scores = Enum.map(@theme_keywords, fn {theme, keywords} ->
      count = Enum.count(words, &(&1 in keywords))
      {theme, count}
    end)

    # Find theme with highest score
    {best_theme, score} = Enum.max_by(scores, fn {_, count} -> count end)

    if score > 0, do: best_theme, else: :default
  end

  defp format_header(title, style, border_style, theme, enable_color) do
    border = if enable_color do
      AnsiArt.get_border(color_border_style(border_style))
    else
      Map.get(@borders, border_style, @borders.simple)
    end
    ornament = theme_ornament(theme, enable_color)

    case style do
      :minimal ->
        [
          border,
          "  #{title}",
          border,
          ""
        ]
      :ornate ->
        if enable_color do
          # Use colorful frame for ornate style
          frame = AnsiArt.color_frame(title, border_color: :bright_yellow, text_color: :bright_cyan)
          ["", frame, ""]
        else
          [
            "",
            "╔" <> String.duplicate("═", 58) <> "╗",
            "║" <> String.pad_leading("", 58) <> "║",
            "║" <> center_text("#{ornament} #{title} #{ornament}", 58) <> "║",
            "║" <> String.pad_leading("", 58) <> "║",
            "╚" <> String.duplicate("═", 58) <> "╝",
            ""
          ]
        end
      :medieval ->
        if enable_color do
          [
            "",
            "    " <> AnsiArt.divider(:rainbow, 50),
            "",
            "         #{ornament}  " <> AnsiArt.colorize(String.upcase(title), :bright_yellow) <> "  #{ornament}",
            "",
            "    " <> AnsiArt.divider(:rainbow, 50),
            ""
          ]
        else
          [
            "",
            "    " <> border,
            "",
            "         #{ornament}  #{String.upcase(title)}  #{ornament}",
            "",
            "    " <> border,
            ""
          ]
        end
      _ ->
        [border, "  #{title}", border, ""]
    end
  end

  defp format_illustration(theme, enable_color) do
    # Use AnsiArt for color, PhlogArt for plain ASCII
    art = if enable_color do
      AnsiArt.get_art(theme)
    else
      PhlogArt.get_art(theme)
    end

    # Center and indent the art
    lines = art
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&("    " <> &1))

    lines ++ [""]
  end

  defp format_body(body, host, port, enable_drop_cap, style, enable_color) do
    # Convert markdown to gopher format
    converted = markdown_to_gopher(body, host, port)

    if enable_drop_cap and String.length(converted) > 0 do
      {drop_cap, rest} = create_drop_cap(converted, enable_color)

      # Format drop cap with text flowing around it
      drop_cap_lines = String.split(drop_cap, "\n")
      rest_lines = String.split(rest, "\n")

      # Merge drop cap with first few lines of text
      merged = merge_drop_cap(drop_cap_lines, rest_lines, style)

      merged ++ [""]
    else
      String.split(converted, "\n") ++ [""]
    end
  end

  defp merge_drop_cap(cap_lines, text_lines, _style) do
    cap_height = length(cap_lines)
    cap_width = cap_lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)

    # Take first few lines of text to flow around drop cap
    {flow_lines, remaining} = Enum.split(text_lines, cap_height)

    # Merge cap lines with text
    merged = Enum.zip_with([cap_lines, flow_lines ++ List.duplicate("", cap_height)], fn [cap, text] ->
      padded_cap = String.pad_trailing(cap, cap_width + 2)
      padded_cap <> text
    end)
    |> Enum.take(cap_height)

    merged ++ remaining
  end

  defp format_footer(style, border_style, enable_color) do
    border = if enable_color do
      AnsiArt.get_border(color_border_style(border_style))
    else
      Map.get(@borders, border_style, @borders.simple)
    end

    case style do
      :minimal ->
        [border]
      :ornate ->
        if enable_color do
          [
            "",
            "    " <> AnsiArt.divider(:gold, 50),
            "    " <> center_text(AnsiArt.colorize("❦ ❦ ❦", :bright_magenta), 50),
            ""
          ]
        else
          [
            "",
            "    " <> border,
            "    " <> center_text("❦ ❦ ❦", String.length(border)),
            ""
          ]
        end
      :medieval ->
        if enable_color do
          [
            "",
            "    " <> AnsiArt.divider(:magic, 50),
            "    " <> center_text(AnsiArt.colorize("~ Finis ~", :bright_cyan), 50),
            "    " <> AnsiArt.divider(:magic, 50),
            ""
          ]
        else
          [
            "",
            "    " <> @borders.vine,
            "    " <> center_text("~ Finis ~", String.length(@borders.vine)),
            "    " <> @borders.vine,
            ""
          ]
        end
      _ ->
        [border]
    end
  end

  defp theme_ornament(theme, enable_color) do
    ornament = case theme do
      :technology -> "⚙"
      :nature -> "🌿"
      :adventure -> "⚔"
      :knowledge -> "📖"
      :music -> "♫"
      :space -> "★"
      :fantasy -> "⚔"
      :food -> "❦"
      :home -> "♥"
      :time -> "⌛"
      _ -> "❦"
    end

    if enable_color do
      color = case theme do
        :technology -> :bright_cyan
        :nature -> :bright_green
        :adventure -> :bright_red
        :knowledge -> :bright_yellow
        :music -> :bright_magenta
        :space -> :bright_blue
        :fantasy -> :bright_red
        :food -> :yellow
        :home -> :bright_red
        :time -> :bright_yellow
        _ -> :bright_magenta
      end
      AnsiArt.colorize(ornament, color)
    else
      ornament
    end
  end

  defp color_border_style(border_style) do
    case border_style do
      :simple -> :rainbow
      :ornate -> :gold
      :vine -> :forest
      :celtic -> :magic
      :wave -> :ocean
      :dots -> :rainbow
      :stars -> :magic
      :diamond -> :gold
      _ -> :rainbow
    end
  end

  defp center_text(text, width) do
    text_len = String.length(text)
    if text_len >= width do
      text
    else
      padding = div(width - text_len, 2)
      String.duplicate(" ", padding) <> text <> String.duplicate(" ", width - padding - text_len)
    end
  end

  # Markdown conversion functions

  defp convert_headers(text) do
    text
    |> (fn t -> Regex.replace(~r/^### (.+)$/m, t, fn _, title ->
      "\n    ── #{title} ──\n"
    end) end).()
    |> (fn t -> Regex.replace(~r/^## (.+)$/m, t, fn _, title ->
      "\n  ═══ #{title} ═══\n"
    end) end).()
    |> (fn t -> Regex.replace(~r/^# (.+)$/m, t, fn _, title ->
      "\n╔═══ #{String.upcase(title)} ═══╗\n"
    end) end).()
  end

  defp convert_links(text, host, port) do
    # Markdown links: [text](url)
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, text, fn _, link_text, url ->
      convert_url_to_gopher(link_text, url, host, port)
    end)
  end

  defp convert_images(text, host, port) do
    # Markdown images: ![alt](url)
    Regex.replace(~r/!\[([^\]]*)\]\(([^)]+)\)/, text, fn _, alt, url ->
      # Determine image type
      ext = url |> String.downcase() |> Path.extname()
      type = if ext in [".gif"], do: "g", else: "I"

      alt_text = if alt == "", do: "Image", else: alt

      if String.starts_with?(url, "gopher://") do
        # Parse gopher URL
        case parse_gopher_url(url) do
          {:ok, g_host, g_port, selector} ->
            "#{type}#{alt_text}\t#{selector}\t#{g_host}\t#{g_port}"
          _ ->
            "[Image: #{alt_text}]"
        end
      else
        # Assume local path
        "#{type}#{alt_text}\t#{url}\t#{host}\t#{port}"
      end
    end)
  end

  defp convert_code_blocks(text) do
    # Fenced code blocks: ```code```
    result = Regex.replace(~r/```(\w*)\n([\s\S]*?)```/, text, fn _, _lang, code ->
      code_lines = code
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(fn line -> "    │ " <> line end)
      |> Enum.join("\n")

      "\n    ┌────────────────────────────────────────\n" <>
      code_lines <>
      "\n    └────────────────────────────────────────\n"
    end)
    # Inline code: `code`
    String.replace(result, ~r/`([^`]+)`/, "「\\1」")
  end

  defp convert_lists(text) do
    text
    # Unordered lists
    |> String.replace(~r/^(\s*)[-*] (.+)$/m, "\\1  • \\2")
    # Ordered lists
    |> String.replace(~r/^(\s*)(\d+)\. (.+)$/m, "\\1  \\2. \\3")
  end

  defp convert_emphasis(text) do
    text
    # Bold: **text** or __text__
    |> String.replace(~r/\*\*([^*]+)\*\*/, "⟦\\1⟧")
    |> String.replace(~r/__([^_]+)__/, "⟦\\1⟧")
    # Italic: *text* or _text_
    |> String.replace(~r/\*([^*]+)\*/, "~\\1~")
    |> String.replace(~r/_([^_]+)_/, "~\\1~")
  end

  defp convert_blockquotes(text) do
    String.replace(text, ~r/^> (.+)$/m, "    ┃ \\1")
  end

  defp auto_detect_urls(text, host, port) do
    # Detect standalone URLs and convert them
    # HTTP/HTTPS URLs
    result = Regex.replace(~r/(?<![(\[])(https?:\/\/[^\s\)]+)/, text, fn _, url ->
      "hURL:#{url}\tURL:#{url}\t#{host}\t#{port}"
    end)
    # Gopher URLs
    result = Regex.replace(~r/(?<![(\[])(gopher:\/\/[^\s\)]+)/, result, fn _, url ->
      case parse_gopher_url(url) do
        {:ok, g_host, g_port, selector} ->
          "1#{url}\t#{selector}\t#{g_host}\t#{g_port}"
        _ ->
          url
      end
    end)
    # Email addresses
    Regex.replace(~r/([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/, result, fn _, email ->
      "    ✉ #{email}"
    end)
  end

  defp convert_url_to_gopher(link_text, url, host, port) do
    cond do
      String.starts_with?(url, "gopher://") ->
        case parse_gopher_url(url) do
          {:ok, g_host, g_port, selector} ->
            "1#{link_text}\t#{selector}\t#{g_host}\t#{g_port}"
          _ ->
            "[#{link_text}](#{url})"
        end

      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        "hURL:#{url}\tURL:#{url}\t#{host}\t#{port}"

      String.starts_with?(url, "/") ->
        # Local path
        "1#{link_text}\t#{url}\t#{host}\t#{port}"

      true ->
        "[#{link_text}](#{url})"
    end
  end

  defp parse_gopher_url(url) do
    # Parse gopher://host[:port][/type][/selector]
    case URI.parse(url) do
      %URI{host: host, port: port, path: path} when not is_nil(host) ->
        port = port || 70
        selector = path || "/"
        {:ok, host, port, selector}
      _ ->
        :error
    end
  end
end
