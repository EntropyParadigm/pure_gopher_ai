defmodule PureGopherAi.Gophermap do
  @moduledoc """
  Gophermap parser and static content server.

  Supports standard gophermap format:
  - Type character + Display text + TAB + Selector + TAB + Host + TAB + Port
  - Info lines (type 'i') can omit selector/host/port
  - Comments start with #
  - Auto-generates directory listings when no gophermap exists

  Item Types:
  - 0: Text file
  - 1: Directory/Menu
  - 2: CSO phone-book server
  - 3: Error
  - 4: BinHexed Macintosh file
  - 5: DOS binary archive
  - 6: UNIX uuencoded file
  - 7: Search
  - 8: Telnet session
  - 9: Binary file
  - g: GIF image
  - h: HTML file
  - i: Info/text (non-selectable)
  - I: Image (generic)
  - s: Sound file
  """

  require Logger

  @type_map %{
    ".txt" => "0",
    ".md" => "0",
    ".text" => "0",
    ".log" => "0",
    ".gif" => "g",
    ".jpg" => "I",
    ".jpeg" => "I",
    ".png" => "I",
    ".bmp" => "I",
    ".mp3" => "s",
    ".wav" => "s",
    ".ogg" => "s",
    ".html" => "h",
    ".htm" => "h",
    ".zip" => "5",
    ".tar" => "9",
    ".gz" => "9",
    ".bin" => "9"
  }

  @doc """
  Gets the configured content directory (uses persistent terms for speed).
  """
  def content_dir do
    PureGopherAi.Config.content_dir()
  end

  @doc """
  Checks if a path exists in the content directory.
  """
  def exists?(selector) do
    path = resolve_path(selector)
    File.exists?(path)
  end

  @doc """
  Resolves a selector to a filesystem path.
  Prevents directory traversal attacks.
  """
  def resolve_path(selector) do
    # Normalize and sanitize the selector
    normalized =
      selector
      |> String.trim_leading("/")
      |> String.replace(~r/\.\./, "")
      |> String.replace(~r/\/+/, "/")

    Path.join(content_dir(), normalized)
  end

  @doc """
  Serves content for a given selector.
  Returns {:ok, content} or {:error, reason}.
  """
  def serve(selector, host, port) do
    path = resolve_path(selector)

    cond do
      !File.exists?(path) ->
        {:error, :not_found}

      File.dir?(path) ->
        serve_directory(path, selector, host, port)

      true ->
        serve_file(path)
    end
  end

  @doc """
  Serves a directory, using gophermap if present, otherwise auto-generating.
  """
  def serve_directory(path, selector, host, port) do
    gophermap_path = Path.join(path, "gophermap")

    if File.exists?(gophermap_path) do
      parse_gophermap(gophermap_path, selector, host, port)
    else
      auto_generate_listing(path, selector, host, port)
    end
  end

  @doc """
  Parses a gophermap file and returns formatted Gopher response.
  """
  def parse_gophermap(gophermap_path, base_selector, default_host, default_port) do
    case File.read(gophermap_path) do
      {:ok, content} ->
        lines =
          content
          |> String.split("\n")
          |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
          |> Enum.map(&parse_gophermap_line(&1, base_selector, default_host, default_port))
          |> Enum.join("\r\n")

        {:ok, lines <> "\r\n.\r\n"}

      {:error, reason} ->
        Logger.error("Failed to read gophermap: #{inspect(reason)}")
        {:error, :read_error}
    end
  end

  defp parse_gophermap_line(line, base_selector, default_host, default_port) do
    case String.split(line, "\t") do
      # Full format: type+display, selector, host, port
      [type_display, selector, host, port] ->
        "#{type_display}\t#{normalize_selector(selector, base_selector)}\t#{host}\t#{port}"

      # Short format: type+display, selector (use defaults for host/port)
      [type_display, selector] ->
        "#{type_display}\t#{normalize_selector(selector, base_selector)}\t#{default_host}\t#{default_port}"

      # Info line (just text, or type 'i' prefix)
      [text] ->
        if String.starts_with?(text, "i") do
          "#{text}\t\t#{default_host}\t#{default_port}"
        else
          "i#{text}\t\t#{default_host}\t#{default_port}"
        end

      _ ->
        "i#{line}\t\t#{default_host}\t#{default_port}"
    end
  end

  defp normalize_selector(selector, base_selector) do
    if String.starts_with?(selector, "/") do
      selector
    else
      Path.join("/#{base_selector}", selector)
      |> String.replace(~r/\/+/, "/")
    end
  end

  @doc """
  Auto-generates a directory listing when no gophermap exists.
  """
  def auto_generate_listing(path, selector, host, port) do
    case File.ls(path) do
      {:ok, entries} ->
        lines =
          entries
          |> Enum.sort()
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.map(&format_entry(&1, path, selector, host, port))
          |> Enum.join("\r\n")

        header = "i=== #{selector || "/"} ===\t\t#{host}\t#{port}\r\ni\t\t#{host}\t#{port}\r\n"
        {:ok, header <> lines <> "\r\n.\r\n"}

      {:error, reason} ->
        Logger.error("Failed to list directory: #{inspect(reason)}")
        {:error, :list_error}
    end
  end

  defp format_entry(name, dir_path, selector, host, port) do
    full_path = Path.join(dir_path, name)
    entry_selector = Path.join("/#{selector}", name) |> String.replace(~r/\/+/, "/")

    type =
      cond do
        File.dir?(full_path) -> "1"
        true -> get_file_type(name)
      end

    "#{type}#{name}\t#{entry_selector}\t#{host}\t#{port}"
  end

  defp get_file_type(filename) do
    ext = Path.extname(filename) |> String.downcase()
    Map.get(@type_map, ext, "9")
  end

  @doc """
  Serves a file's contents.
  """
  def serve_file(path) do
    case File.read(path) do
      {:ok, content} ->
        # Add Gopher terminator for text files
        {:ok, content <> "\r\n.\r\n"}

      {:error, reason} ->
        Logger.error("Failed to read file #{path}: #{inspect(reason)}")
        {:error, :read_error}
    end
  end
end
