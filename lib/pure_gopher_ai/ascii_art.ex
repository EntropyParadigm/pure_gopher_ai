defmodule PureGopherAi.AsciiArt do
  @moduledoc """
  ASCII art generation for the Gopher server.
  Provides text-to-ASCII art conversion using built-in fonts.
  """

  require Logger

  # Simple block font characters (7 rows high)
  @block_font %{
    "A" => [
      "  ███  ",
      " █   █ ",
      "█     █",
      "███████",
      "█     █",
      "█     █",
      "█     █"
    ],
    "B" => [
      "██████ ",
      "█     █",
      "█     █",
      "██████ ",
      "█     █",
      "█     █",
      "██████ "
    ],
    "C" => [
      " █████ ",
      "█     █",
      "█      ",
      "█      ",
      "█      ",
      "█     █",
      " █████ "
    ],
    "D" => [
      "██████ ",
      "█     █",
      "█     █",
      "█     █",
      "█     █",
      "█     █",
      "██████ "
    ],
    "E" => [
      "███████",
      "█      ",
      "█      ",
      "█████  ",
      "█      ",
      "█      ",
      "███████"
    ],
    "F" => [
      "███████",
      "█      ",
      "█      ",
      "█████  ",
      "█      ",
      "█      ",
      "█      "
    ],
    "G" => [
      " █████ ",
      "█     █",
      "█      ",
      "█  ████",
      "█     █",
      "█     █",
      " █████ "
    ],
    "H" => [
      "█     █",
      "█     █",
      "█     █",
      "███████",
      "█     █",
      "█     █",
      "█     █"
    ],
    "I" => [
      "███████",
      "   █   ",
      "   █   ",
      "   █   ",
      "   █   ",
      "   █   ",
      "███████"
    ],
    "J" => [
      "      █",
      "      █",
      "      █",
      "      █",
      "█     █",
      "█     █",
      " █████ "
    ],
    "K" => [
      "█    █ ",
      "█   █  ",
      "█  █   ",
      "███    ",
      "█  █   ",
      "█   █  ",
      "█    █ "
    ],
    "L" => [
      "█      ",
      "█      ",
      "█      ",
      "█      ",
      "█      ",
      "█      ",
      "███████"
    ],
    "M" => [
      "█     █",
      "██   ██",
      "█ █ █ █",
      "█  █  █",
      "█     █",
      "█     █",
      "█     █"
    ],
    "N" => [
      "█     █",
      "██    █",
      "█ █   █",
      "█  █  █",
      "█   █ █",
      "█    ██",
      "█     █"
    ],
    "O" => [
      " █████ ",
      "█     █",
      "█     █",
      "█     █",
      "█     █",
      "█     █",
      " █████ "
    ],
    "P" => [
      "██████ ",
      "█     █",
      "█     █",
      "██████ ",
      "█      ",
      "█      ",
      "█      "
    ],
    "Q" => [
      " █████ ",
      "█     █",
      "█     █",
      "█     █",
      "█   █ █",
      "█    █ ",
      " ████ █"
    ],
    "R" => [
      "██████ ",
      "█     █",
      "█     █",
      "██████ ",
      "█   █  ",
      "█    █ ",
      "█     █"
    ],
    "S" => [
      " █████ ",
      "█     █",
      "█      ",
      " █████ ",
      "      █",
      "█     █",
      " █████ "
    ],
    "T" => [
      "███████",
      "   █   ",
      "   █   ",
      "   █   ",
      "   █   ",
      "   █   ",
      "   █   "
    ],
    "U" => [
      "█     █",
      "█     █",
      "█     █",
      "█     █",
      "█     █",
      "█     █",
      " █████ "
    ],
    "V" => [
      "█     █",
      "█     █",
      "█     █",
      "█     █",
      " █   █ ",
      "  █ █  ",
      "   █   "
    ],
    "W" => [
      "█     █",
      "█     █",
      "█     █",
      "█  █  █",
      "█ █ █ █",
      "██   ██",
      "█     █"
    ],
    "X" => [
      "█     █",
      " █   █ ",
      "  █ █  ",
      "   █   ",
      "  █ █  ",
      " █   █ ",
      "█     █"
    ],
    "Y" => [
      "█     █",
      " █   █ ",
      "  █ █  ",
      "   █   ",
      "   █   ",
      "   █   ",
      "   █   "
    ],
    "Z" => [
      "███████",
      "     █ ",
      "    █  ",
      "   █   ",
      "  █    ",
      " █     ",
      "███████"
    ],
    " " => [
      "   ",
      "   ",
      "   ",
      "   ",
      "   ",
      "   ",
      "   "
    ],
    "0" => [
      " █████ ",
      "█    ██",
      "█   █ █",
      "█  █  █",
      "█ █   █",
      "██    █",
      " █████ "
    ],
    "1" => [
      "  █    ",
      " ██    ",
      "  █    ",
      "  █    ",
      "  █    ",
      "  █    ",
      "███████"
    ],
    "2" => [
      " █████ ",
      "█     █",
      "      █",
      " █████ ",
      "█      ",
      "█      ",
      "███████"
    ],
    "3" => [
      " █████ ",
      "█     █",
      "      █",
      "  ████ ",
      "      █",
      "█     █",
      " █████ "
    ],
    "4" => [
      "█     █",
      "█     █",
      "█     █",
      "███████",
      "      █",
      "      █",
      "      █"
    ],
    "5" => [
      "███████",
      "█      ",
      "█      ",
      "██████ ",
      "      █",
      "█     █",
      " █████ "
    ],
    "6" => [
      " █████ ",
      "█      ",
      "█      ",
      "██████ ",
      "█     █",
      "█     █",
      " █████ "
    ],
    "7" => [
      "███████",
      "      █",
      "     █ ",
      "    █  ",
      "   █   ",
      "   █   ",
      "   █   "
    ],
    "8" => [
      " █████ ",
      "█     █",
      "█     █",
      " █████ ",
      "█     █",
      "█     █",
      " █████ "
    ],
    "9" => [
      " █████ ",
      "█     █",
      "█     █",
      " ██████",
      "      █",
      "      █",
      " █████ "
    ],
    "!" => [
      "  █  ",
      "  █  ",
      "  █  ",
      "  █  ",
      "  █  ",
      "     ",
      "  █  "
    ],
    "?" => [
      " ████ ",
      "█    █",
      "    █ ",
      "   █  ",
      "   █  ",
      "      ",
      "   █  "
    ],
    "." => [
      "   ",
      "   ",
      "   ",
      "   ",
      "   ",
      "   ",
      " █ "
    ],
    "," => [
      "   ",
      "   ",
      "   ",
      "   ",
      "   ",
      " █ ",
      "█  "
    ],
    "-" => [
      "       ",
      "       ",
      "       ",
      "███████",
      "       ",
      "       ",
      "       "
    ],
    ":" => [
      "   ",
      " █ ",
      "   ",
      "   ",
      "   ",
      " █ ",
      "   "
    ]
  }

  # Small font (3 rows high)
  @small_font %{
    "A" => ["▄█▄", "█▀█", "▀ ▀"],
    "B" => ["██▄", "█▄█", "██▀"],
    "C" => ["▄█▀", "█  ", "▀█▄"],
    "D" => ["██▄", "█ █", "██▀"],
    "E" => ["██▀", "█▄ ", "██▄"],
    "F" => ["██▀", "█▄ ", "█  "],
    "G" => ["▄██", "█ ▄", "▀██"],
    "H" => ["█ █", "███", "█ █"],
    "I" => ["███", " █ ", "███"],
    "J" => ["  █", "  █", "██▀"],
    "K" => ["█▄█", "██ ", "█ █"],
    "L" => ["█  ", "█  ", "███"],
    "M" => ["█▄█", "█▀█", "█ █"],
    "N" => ["█▄█", "█▀█", "█ █"],
    "O" => ["▄█▄", "█ █", "▀█▀"],
    "P" => ["██▄", "█▀ ", "█  "],
    "Q" => ["▄█▄", "█ █", "▀█▄"],
    "R" => ["██▄", "██ ", "█ █"],
    "S" => ["▄██", "▀█▄", "██▀"],
    "T" => ["███", " █ ", " █ "],
    "U" => ["█ █", "█ █", "▀█▀"],
    "V" => ["█ █", "█ █", " ▀ "],
    "W" => ["█ █", "█▄█", "█▀█"],
    "X" => ["█ █", " ▀ ", "█ █"],
    "Y" => ["█ █", " █ ", " █ "],
    "Z" => ["██▄", " █ ", "▀██"],
    " " => ["   ", "   ", "   "],
    "0" => ["▄█▄", "█ █", "▀█▀"],
    "1" => ["▄█ ", " █ ", "▄█▄"],
    "2" => ["▀█▄", "▄█▀", "███"],
    "3" => ["██▄", " █▄", "██▀"],
    "4" => ["█ █", "███", "  █"],
    "5" => ["██▀", "▀█▄", "██▀"],
    "6" => ["▄██", "█▄▄", "▀█▀"],
    "7" => ["███", "  █", "  █"],
    "8" => ["▄█▄", "▄█▄", "▀█▀"],
    "9" => ["▄█▄", "▀██", "██▀"],
    "!" => ["█", "█", "▀"],
    "?" => ["█▄", " █", " ▀"],
    "." => [" ", " ", "▀"],
    "-" => ["   ", "▀▀▀", "   "]
  }

  @doc """
  Generates ASCII art from text using the specified font style.
  Available styles: :block (default), :small
  """
  def generate(text, opts \\ []) do
    style = Keyword.get(opts, :style, :block)
    max_width = Keyword.get(opts, :max_width, 80)

    text = text |> String.upcase() |> String.slice(0, div(max_width, 8))

    case style do
      :block -> render_block(text)
      :small -> render_small(text)
      _ -> render_block(text)
    end
  end

  @doc """
  Lists available font styles.
  """
  def list_styles do
    [
      {:block, "Large block letters (7 rows)"},
      {:small, "Compact letters (3 rows)"}
    ]
  end

  @doc """
  Generates a decorative banner.
  """
  def banner(text, opts \\ []) do
    art = generate(text, opts)
    width = art |> String.split("\n") |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    border = String.duplicate("═", width + 4)

    """
    ╔#{border}╗
    ║  #{String.pad_trailing("", width)}  ║
    #{art |> String.split("\n") |> Enum.map(&"║  #{String.pad_trailing(&1, width)}  ║") |> Enum.join("\n")}
    ║  #{String.pad_trailing("", width)}  ║
    ╚#{border}╝
    """
  end

  @doc """
  Generates a simple box around text.
  """
  def box(text) do
    lines = String.split(text, "\n")
    width = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    border = String.duplicate("─", width + 2)

    top = "┌#{border}┐"
    bottom = "└#{border}┘"

    body =
      lines
      |> Enum.map(&"│ #{String.pad_trailing(&1, width)} │")
      |> Enum.join("\n")

    "#{top}\n#{body}\n#{bottom}"
  end

  # Render using block font
  defp render_block(text) do
    chars = String.graphemes(text)

    if Enum.empty?(chars) do
      ""
    else
      0..6
      |> Enum.map(fn row ->
        chars
        |> Enum.map(fn char ->
          case Map.get(@block_font, char) do
            nil -> List.duplicate(" ", 7) |> Enum.at(row, "       ")
            rows -> Enum.at(rows, row, "       ")
          end
        end)
        |> Enum.join(" ")
      end)
      |> Enum.join("\n")
    end
  end

  # Render using small font
  defp render_small(text) do
    chars = String.graphemes(text)

    if Enum.empty?(chars) do
      ""
    else
      0..2
      |> Enum.map(fn row ->
        chars
        |> Enum.map(fn char ->
          case Map.get(@small_font, char) do
            nil -> "   "
            rows -> Enum.at(rows, row, "   ")
          end
        end)
        |> Enum.join(" ")
      end)
      |> Enum.join("\n")
    end
  end
end
