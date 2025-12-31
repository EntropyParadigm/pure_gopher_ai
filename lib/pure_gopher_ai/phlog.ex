defmodule PureGopherAi.Phlog do
  @moduledoc """
  Phlog (Gopher blog) support with dated entries.
  Serves phlog content from a configurable directory with auto-generated indexes.

  Directory structure: phlog/YYYY/MM/DD-title.txt
  """

  require Logger

  @default_entries_per_page 10

  @doc """
  Gets the phlog content directory.
  """
  def content_dir do
    Application.get_env(:pure_gopher_ai, :phlog_dir, "priv/phlog")
  end

  @doc """
  Lists all phlog entries sorted by date (newest first).
  Returns list of {date, title, path} tuples.
  """
  def list_entries do
    dir = content_dir()

    if File.dir?(dir) do
      dir
      |> scan_phlog_directory()
      |> Enum.sort_by(fn {date, _title, _path} -> date end, :desc)
    else
      []
    end
  end

  @doc """
  Gets paginated phlog entries.
  """
  def list_entries(page, per_page \\ @default_entries_per_page) do
    entries = list_entries()
    total = length(entries)
    total_pages = max(1, ceil(total / per_page))

    page = max(1, min(page, total_pages))
    offset = (page - 1) * per_page

    page_entries =
      entries
      |> Enum.drop(offset)
      |> Enum.take(per_page)

    %{
      entries: page_entries,
      page: page,
      total_pages: total_pages,
      total_entries: total,
      per_page: per_page
    }
  end

  @doc """
  Reads a specific phlog entry by path.
  """
  def get_entry(entry_path) do
    full_path = Path.join(content_dir(), entry_path)

    # Security: prevent directory traversal
    if String.contains?(entry_path, "..") do
      {:error, :invalid_path}
    else
      case File.read(full_path) do
        {:ok, content} ->
          {date, title} = parse_entry_filename(entry_path)
          {:ok, %{
            date: date,
            title: title,
            content: content,
            path: entry_path
          }}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Gets entries by year.
  """
  def entries_by_year(year) when is_integer(year) do
    year_str = Integer.to_string(year)

    list_entries()
    |> Enum.filter(fn {date, _title, _path} ->
      String.starts_with?(date, year_str)
    end)
  end

  @doc """
  Gets entries by year and month.
  """
  def entries_by_month(year, month) when is_integer(year) and is_integer(month) do
    year_str = Integer.to_string(year)
    month_str = String.pad_leading(Integer.to_string(month), 2, "0")
    prefix = "#{year_str}/#{month_str}"

    list_entries()
    |> Enum.filter(fn {date, _title, _path} ->
      String.starts_with?(date, prefix)
    end)
  end

  @doc """
  Gets all years that have entries.
  """
  def list_years do
    list_entries()
    |> Enum.map(fn {date, _title, _path} ->
      date |> String.split("/") |> List.first()
    end)
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  @doc """
  Gets all months in a year that have entries.
  """
  def list_months(year) when is_integer(year) do
    year_str = Integer.to_string(year)

    list_entries()
    |> Enum.filter(fn {date, _title, _path} ->
      String.starts_with?(date, year_str)
    end)
    |> Enum.map(fn {date, _title, _path} ->
      date |> String.split("/") |> Enum.at(1)
    end)
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  @doc """
  Generates Atom feed for the phlog.
  """
  def generate_atom_feed(base_url, opts \\ []) do
    entries = Keyword.get(opts, :entries, 20)
    title = Keyword.get(opts, :title, "PureGopherAI Phlog")

    recent_entries =
      list_entries()
      |> Enum.take(entries)

    updated =
      case recent_entries do
        [{date, _, _} | _] -> date_to_iso8601(date)
        [] -> DateTime.utc_now() |> DateTime.to_iso8601()
      end

    entries_xml =
      recent_entries
      |> Enum.map(fn {date, entry_title, path} ->
        case get_entry(path) do
          {:ok, %{content: content}} ->
            """
              <entry>
                <title>#{escape_xml(entry_title)}</title>
                <link href="#{base_url}/phlog/#{path}"/>
                <id>#{base_url}/phlog/#{path}</id>
                <updated>#{date_to_iso8601(date)}</updated>
                <content type="text">#{escape_xml(content)}</content>
              </entry>
            """
          _ -> ""
        end
      end)
      |> Enum.join("\n")

    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>#{escape_xml(title)}</title>
      <link href="#{base_url}/phlog"/>
      <updated>#{updated}</updated>
      <id>#{base_url}/phlog</id>
    #{entries_xml}
    </feed>
    """
  end

  # Private functions

  defp scan_phlog_directory(dir) do
    case File.ls(dir) do
      {:ok, items} ->
        Enum.flat_map(items, fn item ->
          full_path = Path.join(dir, item)

          cond do
            File.dir?(full_path) and Regex.match?(~r/^\d{4}$/, item) ->
              # Year directory
              scan_year_directory(full_path, item)

            File.regular?(full_path) and String.ends_with?(item, ".txt") ->
              # Entry in root (legacy support)
              case parse_entry_filename(item) do
                {date, title} when date != "" -> [{date, title, item}]
                _ -> []
              end

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp scan_year_directory(year_dir, year) do
    case File.ls(year_dir) do
      {:ok, items} ->
        Enum.flat_map(items, fn item ->
          full_path = Path.join(year_dir, item)

          cond do
            File.dir?(full_path) and Regex.match?(~r/^\d{2}$/, item) ->
              # Month directory
              scan_month_directory(full_path, year, item)

            File.regular?(full_path) and String.ends_with?(item, ".txt") ->
              # Entry directly in year
              {_date, title} = parse_entry_filename(item)
              day = String.slice(item, 0, 2)
              [{"#{year}/01/#{day}", title, "#{year}/#{item}"}]

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp scan_month_directory(month_dir, year, month) do
    case File.ls(month_dir) do
      {:ok, items} ->
        Enum.flat_map(items, fn item ->
          full_path = Path.join(month_dir, item)

          if File.regular?(full_path) and String.ends_with?(item, ".txt") do
            {_date, title} = parse_entry_filename(item)
            day = String.slice(item, 0, 2)
            [{"#{year}/#{month}/#{day}", title, "#{year}/#{month}/#{item}"}]
          else
            []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp parse_entry_filename(filename) do
    # Expected format: DD-title.txt or YYYY-MM-DD-title.txt
    basename = Path.basename(filename, ".txt")

    cond do
      # Format: DD-title
      Regex.match?(~r/^\d{2}-/, basename) ->
        [day, rest] = String.split(basename, "-", parts: 2)
        title = rest |> String.replace("-", " ") |> String.trim()
        {day, humanize_title(title)}

      # Format: YYYY-MM-DD-title
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}-/, basename) ->
        [year, month, day | rest] = String.split(basename, "-", parts: 4)
        title = Enum.join(rest, "-") |> String.replace("-", " ") |> String.trim()
        {"#{year}/#{month}/#{day}", humanize_title(title)}

      true ->
        {"", humanize_title(basename)}
    end
  end

  defp humanize_title(title) do
    title
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp date_to_iso8601(date_str) do
    # date_str is "YYYY/MM/DD" format
    parts = String.split(date_str, "/")

    case parts do
      [year, month, day] ->
        "#{year}-#{month}-#{day}T00:00:00Z"
      [year, month] ->
        "#{year}-#{month}-01T00:00:00Z"
      [year] ->
        "#{year}-01-01T00:00:00Z"
      _ ->
        DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp escape_xml(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
