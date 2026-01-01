defmodule PureGopherAi.Search do
  @moduledoc """
  Full-text search across gophermap content and phlog entries.
  Implements Gopher Type 7 search functionality.
  """

  require Logger

  alias PureGopherAi.Gophermap
  alias PureGopherAi.Phlog

  @doc """
  Searches across all content (gophermap and phlog).
  Returns a list of {type, title, selector, snippet} tuples.
  """
  def search(query, opts \\ []) do
    query = String.trim(query)
    max_results = Keyword.get(opts, :max_results, 50)

    if String.length(query) < 2 do
      []
    else
      query_terms = parse_query(query)

      # Search in parallel
      tasks = [
        Task.async(fn -> search_gophermap(query_terms) end),
        Task.async(fn -> search_phlog(query_terms) end)
      ]

      results =
        tasks
        |> Enum.map(&Task.await(&1, 5000))
        |> List.flatten()
        |> Enum.sort_by(fn {_type, _title, _selector, _snippet, score} -> score end, :desc)
        |> Enum.take(max_results)
        |> Enum.map(fn {type, title, selector, snippet, _score} -> {type, title, selector, snippet} end)

      Logger.info("Search for '#{query}' returned #{length(results)} results")
      results
    end
  end

  @doc """
  Searches only gophermap content.
  """
  def search_gophermap(query_terms) when is_list(query_terms) do
    content_dir = Gophermap.content_dir()

    if File.dir?(content_dir) do
      scan_directory(content_dir, "", query_terms, :file)
    else
      []
    end
  end

  def search_gophermap(query) when is_binary(query) do
    search_gophermap(parse_query(query))
  end

  @doc """
  Searches only phlog entries.
  """
  def search_phlog(query_terms) when is_list(query_terms) do
    Phlog.list_entries()
    |> Enum.map(fn {date, title, path} ->
      case Phlog.get_entry(path) do
        {:ok, entry} ->
          content = "#{entry.title}\n#{entry.content}"
          score = calculate_score(content, query_terms)

          if score > 0 do
            snippet = extract_snippet(entry.content, query_terms)
            {:phlog, "[#{date}] #{title}", "/phlog/entry/#{path}", snippet, score}
          else
            nil
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def search_phlog(query) when is_binary(query) do
    search_phlog(parse_query(query))
  end

  # Parse query into search terms
  defp parse_query(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq()
  end

  # Scan directory for matching files
  defp scan_directory(base_dir, relative_path, query_terms, _type) do
    full_path = Path.join(base_dir, relative_path)

    case File.ls(full_path) do
      {:ok, items} ->
        Enum.flat_map(items, fn item ->
          item_path = Path.join(relative_path, item)
          item_full_path = Path.join(base_dir, item_path)

          cond do
            File.dir?(item_full_path) ->
              # Recurse into subdirectories
              scan_directory(base_dir, item_path, query_terms, :dir)

            File.regular?(item_full_path) and searchable_file?(item) ->
              # Search file content
              search_file(item_full_path, item_path, item, query_terms)

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp searchable_file?(filename) do
    ext = Path.extname(filename) |> String.downcase()
    ext in [".txt", ".md", ".gophermap", ""]
  end

  defp search_file(full_path, relative_path, filename, query_terms) do
    case File.read(full_path) do
      {:ok, content} ->
        # Include filename in search
        searchable = "#{filename}\n#{content}"
        score = calculate_score(searchable, query_terms)

        if score > 0 do
          title = filename_to_title(filename)
          snippet = extract_snippet(content, query_terms)
          selector = "/files/#{relative_path}"
          [{:file, title, selector, snippet, score}]
        else
          []
        end

      {:error, _} ->
        []
    end
  end

  # Calculate relevance score
  defp calculate_score(content, query_terms) do
    content_lower = String.downcase(content)

    Enum.reduce(query_terms, 0, fn term, acc ->
      # Count occurrences
      matches =
        content_lower
        |> String.split(term)
        |> length()
        |> Kernel.-(1)

      # Bonus for title/first line matches
      first_line =
        content_lower
        |> String.split("\n", parts: 2)
        |> List.first()
        |> Kernel.||("")

      title_bonus = if String.contains?(first_line, term), do: 5, else: 0

      acc + matches + title_bonus
    end)
  end

  # Extract snippet around first match
  defp extract_snippet(content, query_terms) do
    content_lower = String.downcase(content)

    # Find first matching term position
    first_match =
      query_terms
      |> Enum.map(fn term ->
        case :binary.match(content_lower, term) do
          {pos, _len} -> pos
          :nomatch -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> 0 end)

    # Extract snippet around match
    snippet_start = max(0, first_match - 50)
    snippet_length = 150

    snippet =
      content
      |> String.slice(snippet_start, snippet_length)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    prefix = if snippet_start > 0, do: "...", else: ""
    suffix = if String.length(content) > snippet_start + snippet_length, do: "...", else: ""

    "#{prefix}#{snippet}#{suffix}"
  end

  defp filename_to_title(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/\.[^.]+$/, "")
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
