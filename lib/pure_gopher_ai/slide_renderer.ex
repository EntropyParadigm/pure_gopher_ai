defmodule PureGopherAi.SlideRenderer do
  @moduledoc """
  Renders terminal slides with ASCII/ANSI art visuals.

  Supports:
  - Multiple slide templates
  - ASCII art borders and decorations
  - ANSI 16-color support for terminals
  - Themed presentations
  - Progress indicators
  """

  alias PureGopherAi.AnsiArt
  alias PureGopherAi.PhlogArt

  @width 78
  @height 24

  # Themes with their visual styles
  @themes %{
    default: %{
      border: :double,
      title_style: :centered,
      accent_color: :bright_cyan,
      border_color: :bright_white
    },
    minimal: %{
      border: :simple,
      title_style: :left,
      accent_color: :white,
      border_color: :bright_black
    },
    retro: %{
      border: :stars,
      title_style: :banner,
      accent_color: :bright_green,
      border_color: :green
    },
    elegant: %{
      border: :ornate,
      title_style: :centered,
      accent_color: :bright_yellow,
      border_color: :yellow
    },
    tech: %{
      border: :matrix,
      title_style: :left,
      accent_color: :bright_cyan,
      border_color: :cyan
    },
    fantasy: %{
      border: :medieval,
      title_style: :banner,
      accent_color: :bright_magenta,
      border_color: :magenta
    }
  }

  # Border styles
  @borders %{
    simple: %{tl: "+", tr: "+", bl: "+", br: "+", h: "-", v: "|"},
    double: %{tl: "╔", tr: "╗", bl: "╚", br: "╝", h: "═", v: "║"},
    rounded: %{tl: "╭", tr: "╮", bl: "╰", br: "╯", h: "─", v: "│"},
    heavy: %{tl: "┏", tr: "┓", bl: "┗", br: "┛", h: "━", v: "┃"},
    stars: %{tl: "★", tr: "★", bl: "★", br: "★", h: "☆", v: "★"},
    ornate: %{tl: "❖", tr: "❖", bl: "❖", br: "❖", h: "═", v: "║"},
    matrix: %{tl: "[", tr: "]", bl: "[", br: "]", h: "=", v: "|"},
    medieval: %{tl: "╔", tr: "╗", bl: "╚", br: "╝", h: "═", v: "║"}
  }

  @doc """
  Renders a complete slide deck as a list of rendered slides.
  """
  def render_deck(deck, opts \\ []) do
    color_enabled = Keyword.get(opts, :color, deck.color_enabled)
    theme = Map.get(@themes, deck.theme, @themes.default)

    deck.slides
    |> Enum.with_index(1)
    |> Enum.map(fn {slide, index} ->
      render_slide(slide, index, length(deck.slides), deck.title, theme, color_enabled)
    end)
  end

  @doc """
  Renders a single slide.
  """
  def render_slide(slide, index, total, deck_title, theme, color_enabled) do
    border = Map.get(@borders, theme.border, @borders.double)

    lines = []

    # Top border with deck title
    lines = lines ++ [render_top_border(deck_title, border, theme, color_enabled)]

    # Empty line
    lines = lines ++ [render_empty_line(border, color_enabled, theme)]

    # Slide content based on type
    content_lines = render_slide_content(slide, theme, color_enabled)
    lines = lines ++ content_lines

    # Pad to fill height
    current_height = length(lines)
    padding_needed = @height - current_height - 2  # -2 for bottom lines
    lines = lines ++ List.duplicate(render_empty_line(border, color_enabled, theme), max(0, padding_needed))

    # Progress bar
    lines = lines ++ [render_progress_bar(index, total, border, theme, color_enabled)]

    # Bottom border
    lines = lines ++ [render_bottom_border(border, theme, color_enabled)]

    Enum.join(lines, "\n")
  end

  @doc """
  Renders a slide for Gopher protocol (returns menu items).
  """
  def render_for_gopher(deck, slide_index, host, port) do
    slide = Enum.at(deck.slides, slide_index)
    total = length(deck.slides)
    theme = Map.get(@themes, deck.theme, @themes.default)

    rendered = render_slide(slide, slide_index + 1, total, deck.title, theme, false)

    # Convert to Gopher info lines
    lines = rendered
    |> String.split("\n")
    |> Enum.map(fn line -> "i#{line}\t\t#{host}\t#{port}" end)

    # Add navigation
    nav = []
    nav = if slide_index > 0 do
      nav ++ ["1< Previous Slide\t/slides/view/#{deck.id}/#{slide_index - 1}\t#{host}\t#{port}"]
    else
      nav
    end

    nav = if slide_index < total - 1 do
      nav ++ ["1> Next Slide\t/slides/view/#{deck.id}/#{slide_index + 1}\t#{host}\t#{port}"]
    else
      nav
    end

    nav = nav ++ [
      "i\t\t#{host}\t#{port}",
      "1Back to Deck Overview\t/slides/view/#{deck.id}\t#{host}\t#{port}",
      "0Export as Markdown\t/slides/export/#{deck.id}/md\t#{host}\t#{port}",
      "0Export as Plain Text\t/slides/export/#{deck.id}/txt\t#{host}\t#{port}"
    ]

    Enum.join(lines ++ ["i\t\t#{host}\t#{port}"] ++ nav, "\r\n") <> "\r\n.\r\n"
  end

  @doc """
  Returns available themes.
  """
  def themes, do: Map.keys(@themes)

  # Private rendering functions

  defp render_top_border(title, border, theme, color_enabled) do
    title_text = " #{title} "
    title_len = String.length(title_text)
    side_len = div(@width - title_len - 2, 2)

    left = border.tl <> String.duplicate(border.h, side_len)
    right = String.duplicate(border.h, @width - side_len - title_len - 2) <> border.tr

    line = left <> title_text <> right

    if color_enabled do
      colorize_border(line, theme)
    else
      line
    end
  end

  defp render_bottom_border(border, theme, color_enabled) do
    line = border.bl <> String.duplicate(border.h, @width - 2) <> border.br

    if color_enabled do
      colorize_border(line, theme)
    else
      line
    end
  end

  defp render_empty_line(border, color_enabled, theme) do
    line = border.v <> String.duplicate(" ", @width - 2) <> border.v

    if color_enabled do
      colorize_border(line, theme)
    else
      line
    end
  end

  defp render_progress_bar(current, total, border, theme, color_enabled) do
    progress_width = @width - 20
    filled = round(current / total * progress_width)
    empty = progress_width - filled

    bar = "[" <> String.duplicate("█", filled) <> String.duplicate("░", empty) <> "]"
    page_info = " #{current}/#{total} "

    content = "  #{bar}#{page_info}"
    padding = @width - String.length(content) - 2
    line = border.v <> content <> String.duplicate(" ", max(0, padding)) <> border.v

    if color_enabled do
      colorize_border(line, theme)
    else
      line
    end
  end

  defp render_slide_content(slide, theme, color_enabled) do
    case slide.type do
      :title -> render_title_slide(slide, theme, color_enabled)
      :content -> render_content_slide(slide, theme, color_enabled)
      :two_column -> render_two_column_slide(slide, theme, color_enabled)
      :code -> render_code_slide(slide, theme, color_enabled)
      :image -> render_image_slide(slide, theme, color_enabled)
      :quote -> render_quote_slide(slide, theme, color_enabled)
      :list -> render_list_slide(slide, theme, color_enabled)
      :comparison -> render_comparison_slide(slide, theme, color_enabled)
      _ -> render_content_slide(slide, theme, color_enabled)
    end
  end

  defp render_title_slide(slide, theme, color_enabled) do
    border = Map.get(@borders, theme.border, @borders.double)

    # Build lines list using concatenation
    padding = List.duplicate(render_empty_line(border, color_enabled, theme), 4)

    decor = if color_enabled do
      AnsiArt.divider(:rainbow, @width - 10)
    else
      String.duplicate("═", @width - 10)
    end

    decor_line = wrap_content("     " <> decor, border, color_enabled, theme)
    empty_line = render_empty_line(border, color_enabled, theme)

    # Main title - large and centered
    title = slide.content
    centered_title = center_text(title, @width - 4)

    title_line = if color_enabled do
      wrap_content(AnsiArt.colorize(centered_title, theme.accent_color), border, color_enabled, theme)
    else
      wrap_content(centered_title, border, color_enabled, theme)
    end

    # Subtitle if present in title field
    subtitle_lines = if slide.title != "" do
      subtitle = center_text(slide.title, @width - 4)
      [wrap_content(subtitle, border, color_enabled, theme)]
    else
      []
    end

    # Combine all parts
    padding ++
      [decor_line, empty_line, title_line, empty_line] ++
      subtitle_lines ++
      [empty_line, decor_line]
  end

  defp render_content_slide(slide, theme, color_enabled) do
    border = Map.get(@borders, theme.border, @borders.double)

    # Slide title
    title_lines = if slide.title != "" do
      title_line = "  ▸ #{slide.title}"
      formatted = if color_enabled do
        wrap_content(AnsiArt.colorize(title_line, theme.accent_color), border, color_enabled, theme)
      else
        wrap_content(title_line, border, color_enabled, theme)
      end
      [formatted, render_empty_line(border, color_enabled, theme)]
    else
      []
    end

    # Content
    content_lines = slide.content
    |> String.split("\n")
    |> Enum.flat_map(&wrap_text(&1, @width - 6))
    |> Enum.map(fn line ->
      wrap_content("  " <> line, border, color_enabled, theme)
    end)

    title_lines ++ content_lines
  end

  defp render_code_slide(slide, theme, color_enabled) do
    border = Map.get(@borders, theme.border, @borders.double)

    # Title
    title_lines = if slide.title != "" do
      title_line = "  ▸ #{slide.title}"
      formatted = if color_enabled do
        wrap_content(AnsiArt.colorize(title_line, theme.accent_color), border, color_enabled, theme)
      else
        wrap_content(title_line, border, color_enabled, theme)
      end
      [formatted, render_empty_line(border, color_enabled, theme)]
    else
      []
    end

    # Code box top
    code_border_top = wrap_content("  ┌" <> String.duplicate("─", @width - 8) <> "┐", border, color_enabled, theme)

    # Code content
    code_lines = slide.content
    |> String.split("\n")
    |> Enum.map(fn line ->
      padded = line |> String.pad_trailing(@width - 10) |> String.slice(0, @width - 10)
      code_line = "  │ " <> padded <> " │"

      if color_enabled do
        colored_content = AnsiArt.colorize(padded, :bright_green)
        wrap_content("  │ " <> colored_content <> " │", border, color_enabled, theme)
      else
        wrap_content(code_line, border, color_enabled, theme)
      end
    end)

    # Code box bottom
    code_border_bottom = wrap_content("  └" <> String.duplicate("─", @width - 8) <> "┘", border, color_enabled, theme)

    title_lines ++ [code_border_top] ++ code_lines ++ [code_border_bottom]
  end

  defp render_quote_slide(slide, theme, color_enabled) do
    border = Map.get(@borders, theme.border, @borders.double)
    empty_line = render_empty_line(border, color_enabled, theme)

    # Vertical padding
    padding = List.duplicate(empty_line, 2)

    # Large quote mark
    quote_mark = "      ❝"
    open_quote_line = if color_enabled do
      wrap_content(AnsiArt.colorize(quote_mark, theme.accent_color), border, color_enabled, theme)
    else
      wrap_content(quote_mark, border, color_enabled, theme)
    end

    # Quote content - wrapped and indented
    quote_lines = slide.content
    |> String.split("\n")
    |> Enum.flat_map(&wrap_text(&1, @width - 16))
    |> Enum.map(fn line ->
      content = "        " <> line
      if color_enabled do
        wrap_content(AnsiArt.colorize(content, :bright_white), border, color_enabled, theme)
      else
        wrap_content(content, border, color_enabled, theme)
      end
    end)

    # Closing quote
    close_quote = "                                                              ❞"
    close_quote_line = if color_enabled do
      wrap_content(AnsiArt.colorize(close_quote, theme.accent_color), border, color_enabled, theme)
    else
      wrap_content(close_quote, border, color_enabled, theme)
    end

    # Attribution if in title
    attribution_lines = if slide.title != "" do
      attr = "                                                    — #{slide.title}"
      [empty_line, wrap_content(attr, border, color_enabled, theme)]
    else
      []
    end

    padding ++ [open_quote_line] ++ quote_lines ++ [close_quote_line] ++ attribution_lines
  end

  defp render_list_slide(slide, theme, color_enabled) do
    border = Map.get(@borders, theme.border, @borders.double)

    # Title
    title_lines = if slide.title != "" do
      title_line = "  ▸ #{slide.title}"
      formatted = if color_enabled do
        wrap_content(AnsiArt.colorize(title_line, theme.accent_color), border, color_enabled, theme)
      else
        wrap_content(title_line, border, color_enabled, theme)
      end
      [formatted, render_empty_line(border, color_enabled, theme)]
    else
      []
    end

    # List items with bullets
    bullets = ["•", "◦", "▪", "▫", "►", "▻"]

    list_lines = slide.content
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      bullet = Enum.at(bullets, rem(idx, length(bullets)))
      item_text = "    #{bullet} #{item}"

      if color_enabled do
        colored_bullet = AnsiArt.colorize(bullet, theme.accent_color)
        [wrap_content("    #{colored_bullet} #{item}", border, color_enabled, theme)]
      else
        [wrap_content(item_text, border, color_enabled, theme)]
      end
    end)

    title_lines ++ list_lines
  end

  defp render_two_column_slide(slide, theme, color_enabled) do
    border = Map.get(@borders, theme.border, @borders.double)

    # Title
    title_lines = if slide.title != "" do
      title_line = "  ▸ #{slide.title}"
      formatted = if color_enabled do
        wrap_content(AnsiArt.colorize(title_line, theme.accent_color), border, color_enabled, theme)
      else
        wrap_content(title_line, border, color_enabled, theme)
      end
      [formatted, render_empty_line(border, color_enabled, theme)]
    else
      []
    end

    # Split content by |||
    [left, right] = case String.split(slide.content, "|||") do
      [l, r] -> [String.trim(l), String.trim(r)]
      [l] -> [String.trim(l), ""]
      _ -> ["", ""]
    end

    col_width = div(@width - 10, 2)

    left_lines = wrap_text(left, col_width)
    right_lines = wrap_text(right, col_width)

    max_lines = max(length(left_lines), length(right_lines))

    left_padded = left_lines ++ List.duplicate("", max_lines - length(left_lines))
    right_padded = right_lines ++ List.duplicate("", max_lines - length(right_lines))

    column_lines = Enum.zip(left_padded, right_padded)
    |> Enum.map(fn {l, r} ->
      l_padded = String.pad_trailing(l, col_width)
      r_padded = String.pad_trailing(r, col_width)
      content = "  #{l_padded}  │  #{r_padded}"
      wrap_content(content, border, color_enabled, theme)
    end)

    title_lines ++ column_lines
  end

  defp render_image_slide(slide, theme, color_enabled) do
    border = Map.get(@borders, theme.border, @borders.double)

    # Title
    title_lines = if slide.title != "" do
      title_line = "  ▸ #{slide.title}"
      formatted = if color_enabled do
        wrap_content(AnsiArt.colorize(title_line, theme.accent_color), border, color_enabled, theme)
      else
        wrap_content(title_line, border, color_enabled, theme)
      end
      [formatted, render_empty_line(border, color_enabled, theme)]
    else
      []
    end

    # Get themed ASCII art if content matches a theme name
    art = cond do
      slide.content in Enum.map(PhlogArt.themes(), &Atom.to_string/1) ->
        theme_atom = String.to_existing_atom(slide.content)
        if color_enabled do
          AnsiArt.get_art(theme_atom)
        else
          PhlogArt.get_art(theme_atom)
        end

      true ->
        # Use content as custom art
        slide.content
    end

    # Center the art
    art_lines = art
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(fn line ->
      centered = center_text(line, @width - 4)
      wrap_content(centered, border, color_enabled, theme)
    end)

    title_lines ++ art_lines
  end

  defp render_comparison_slide(slide, theme, color_enabled) do
    # Similar to two-column but with VS styling
    border = Map.get(@borders, theme.border, @borders.double)
    empty_line = render_empty_line(border, color_enabled, theme)

    # Title
    title_lines = if slide.title != "" do
      title_line = "  ▸ #{slide.title}"
      formatted = if color_enabled do
        wrap_content(AnsiArt.colorize(title_line, theme.accent_color), border, color_enabled, theme)
      else
        wrap_content(title_line, border, color_enabled, theme)
      end
      [formatted, empty_line]
    else
      []
    end

    # VS header
    vs_text = center_text("───────── VS ─────────", @width - 4)
    vs_line = if color_enabled do
      wrap_content(AnsiArt.colorize(vs_text, :bright_red), border, color_enabled, theme)
    else
      wrap_content(vs_text, border, color_enabled, theme)
    end

    # Content as two column
    column_content = render_two_column_slide(%{slide | title: ""}, theme, color_enabled)

    title_lines ++ [vs_line, empty_line] ++ column_content
  end

  # Helper functions

  defp wrap_content(content, border, _color_enabled, _theme) do
    content_len = String.length(AnsiArt.strip_ansi(content))
    padding = @width - content_len - 2

    if padding > 0 do
      border.v <> content <> String.duplicate(" ", padding) <> border.v
    else
      border.v <> String.slice(content, 0, @width - 2) <> border.v
    end
  end

  defp colorize_border(line, theme) do
    AnsiArt.colorize(line, theme.border_color)
  end

  defp center_text(text, width) do
    text_len = String.length(text)
    if text_len >= width do
      String.slice(text, 0, width)
    else
      padding = div(width - text_len, 2)
      String.duplicate(" ", padding) <> text
    end
  end

  defp wrap_text(text, max_width) do
    words = String.split(text, " ")

    {lines, current} = Enum.reduce(words, {[], ""}, fn word, {lines, current} ->
      if current == "" do
        {lines, word}
      else
        test = current <> " " <> word
        if String.length(test) <= max_width do
          {lines, test}
        else
          {lines ++ [current], word}
        end
      end
    end)

    if current != "" do
      lines ++ [current]
    else
      lines
    end
  end
end
