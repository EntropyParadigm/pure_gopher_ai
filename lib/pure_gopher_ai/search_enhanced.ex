defmodule PureGopherAi.SearchEnhanced do
  @moduledoc """
  Enhanced search with fuzzy matching, filters, and advanced queries.

  Features:
  - Fuzzy/typo-tolerant matching
  - Content type filters
  - Date range filters
  - Author/user filters
  - Phrase search with quotes
  - Exclude terms with minus
  """

  alias PureGopherAi.Search
  alias PureGopherAi.UserPhlog
  alias PureGopherAi.Guestbook
  alias PureGopherAi.BulletinBoard
  alias PureGopherAi.UserProfiles

  @content_types [:all, :phlog, :files, :users, :guestbook, :bulletin]

  @doc """
  Advanced search with filters and fuzzy matching.

  Options:
  - :type - Content type filter (:all, :phlog, :files, :users, :guestbook, :bulletin)
  - :fuzzy - Enable fuzzy matching (default: true)
  - :author - Filter by author/username
  - :since - Date filter (ISO8601 string or Date)
  - :until - Date filter (ISO8601 string or Date)
  - :max_results - Maximum results (default: 50)
  """
  def search(query, opts \\ []) do
    query = String.trim(query)
    content_type = Keyword.get(opts, :type, :all)
    fuzzy = Keyword.get(opts, :fuzzy, true)
    author = Keyword.get(opts, :author)
    since = Keyword.get(opts, :since)
    until_date = Keyword.get(opts, :until)
    max_results = Keyword.get(opts, :max_results, 50)

    if String.length(query) < 2 do
      {:ok, []}
    else
      # Parse advanced query syntax
      {must_terms, exclude_terms, phrases} = parse_advanced_query(query)

      # Generate fuzzy variants if enabled
      search_terms = if fuzzy do
        must_terms ++ generate_fuzzy_variants(must_terms)
      else
        must_terms
      end

      # Search based on content type
      results = case content_type do
        :all ->
          search_all(search_terms, phrases, exclude_terms, author, since, until_date)
        :phlog ->
          search_phlog(search_terms, phrases, exclude_terms, author, since, until_date)
        :files ->
          Search.search_gophermap(must_terms)
        :users ->
          search_users(search_terms, exclude_terms)
        :guestbook ->
          search_guestbook(search_terms, phrases, exclude_terms, since, until_date)
        :bulletin ->
          search_bulletin(search_terms, phrases, exclude_terms, author, since, until_date)
        _ ->
          []
      end

      # Sort by score and limit
      filtered = results
        |> Enum.sort_by(fn r -> -Map.get(r, :score, 0) end)
        |> Enum.take(max_results)

      {:ok, filtered}
    end
  end

  @doc """
  Returns available content types for filtering.
  """
  def content_types, do: @content_types

  @doc """
  Performs a simple fuzzy search (typo-tolerant).
  """
  def fuzzy_search(query, opts \\ []) do
    search(query, Keyword.put(opts, :fuzzy, true))
  end

  # Parse advanced query syntax
  defp parse_advanced_query(query) do
    # Extract phrases in quotes
    {phrases, remaining} = extract_phrases(query)

    # Split remaining into terms
    terms = remaining
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&String.downcase/1)

    # Separate must-have and exclude terms
    {exclude, must} = Enum.split_with(terms, &String.starts_with?(&1, "-"))

    must_terms = must |> Enum.reject(&(String.length(&1) < 2))
    exclude_terms = exclude
      |> Enum.map(&String.trim_leading(&1, "-"))
      |> Enum.reject(&(String.length(&1) < 2))

    {must_terms, exclude_terms, phrases}
  end

  defp extract_phrases(query) do
    # Match "quoted phrases"
    regex = ~r/"([^"]+)"/

    phrases = Regex.scan(regex, query)
      |> Enum.map(fn [_, phrase] -> String.downcase(phrase) end)

    remaining = Regex.replace(regex, query, "")

    {phrases, remaining}
  end

  # Generate fuzzy variants using edit distance
  defp generate_fuzzy_variants(terms) do
    terms
    |> Enum.flat_map(&generate_typo_variants/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in terms))
  end

  defp generate_typo_variants(term) when byte_size(term) < 4, do: []
  defp generate_typo_variants(term) do
    chars = String.graphemes(term)

    # Single character deletions
    deletions = for i <- 0..(length(chars) - 1) do
      List.delete_at(chars, i) |> Enum.join()
    end

    # Adjacent transpositions
    transpositions = for i <- 0..(length(chars) - 2) do
      chars
      |> List.update_at(i, fn _ -> Enum.at(chars, i + 1) end)
      |> List.update_at(i + 1, fn _ -> Enum.at(chars, i) end)
      |> Enum.join()
    end

    # Common substitutions
    substitutions = common_typo_substitutions(term)

    (deletions ++ transpositions ++ substitutions)
    |> Enum.filter(&(String.length(&1) >= 2))
  end

  defp common_typo_substitutions(term) do
    # Common keyboard adjacency typos
    substitutions = %{
      "a" => ["s", "q"],
      "e" => ["w", "r"],
      "i" => ["o", "u"],
      "o" => ["p", "i"],
      "u" => ["y", "i"],
      "n" => ["m", "b"],
      "m" => ["n"],
      "c" => ["v", "x"],
      "v" => ["c", "b"]
    }

    String.graphemes(term)
    |> Enum.with_index()
    |> Enum.flat_map(fn {char, i} ->
      case Map.get(substitutions, char) do
        nil -> []
        subs ->
          Enum.map(subs, fn sub ->
            term
            |> String.graphemes()
            |> List.replace_at(i, sub)
            |> Enum.join()
          end)
      end
    end)
  end

  # Search implementations

  defp search_all(terms, phrases, exclude, author, since, until_date) do
    results = [
      search_phlog(terms, phrases, exclude, author, since, until_date),
      Search.search_gophermap(terms) |> Enum.map(&result_to_map/1),
      search_users(terms, exclude),
      search_guestbook(terms, phrases, exclude, since, until_date),
      search_bulletin(terms, phrases, exclude, author, since, until_date)
    ]
    |> List.flatten()

    results
  end

  defp result_to_map({type, title, selector, snippet, score}) do
    %{type: type, title: title, selector: selector, snippet: snippet, score: score}
  end

  defp result_to_map({type, title, selector, snippet}) do
    %{type: type, title: title, selector: selector, snippet: snippet, score: 1}
  end

  defp search_phlog(terms, phrases, exclude, author, since, until_date) do
    # Get user phlogs
    {:ok, profiles, _} = UserProfiles.list(limit: 1000)

    profiles
    |> Enum.filter(fn p ->
      is_nil(author) or String.downcase(p.username) == String.downcase(author)
    end)
    |> Enum.flat_map(fn profile ->
      case UserPhlog.list_posts(profile.username, limit: 100) do
        {:ok, posts} ->
          posts
          |> filter_by_date(since, until_date, :created_at)
          |> Enum.map(fn post ->
            content = "#{post.title}\n#{post.body}"
            score = calculate_score(content, terms, phrases, exclude)

            if score > 0 do
              %{
                type: :user_phlog,
                title: post.title,
                selector: "/phlog/user/#{profile.username}/#{post.id}",
                snippet: extract_snippet(post.body, terms),
                score: score,
                author: profile.username,
                date: post.created_at
              }
            else
              nil
            end
          end)
          |> Enum.reject(&is_nil/1)
        _ ->
          []
      end
    end)
  end

  defp search_users(terms, exclude) do
    {:ok, profiles, _} = UserProfiles.list(limit: 1000)

    profiles
    |> Enum.map(fn profile ->
      content = "#{profile.username} #{profile.bio || ""} #{Enum.join(profile.interests || [], " ")}"
      score = calculate_score(content, terms, [], exclude)

      if score > 0 do
        %{
          type: :user,
          title: profile.username,
          selector: "/users/#{profile.username}",
          snippet: profile.bio || "(no bio)",
          score: score
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp search_guestbook(terms, phrases, exclude, since, until_date) do
    case Guestbook.list_entries(limit: 500) do
      {:ok, entries} ->
        entries
        |> filter_by_date(since, until_date, :created_at)
        |> Enum.map(fn entry ->
          content = "#{entry.name} #{entry.message}"
          score = calculate_score(content, terms, phrases, exclude)

          if score > 0 do
            %{
              type: :guestbook,
              title: "Guestbook: #{entry.name}",
              selector: "/guestbook",
              snippet: String.slice(entry.message, 0, 100),
              score: score,
              date: entry.created_at
            }
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      _ ->
        []
    end
  end

  defp search_bulletin(terms, _phrases, _exclude, _author, _since, _until_date) do
    # Bulletin board has a different structure (categories/boards)
    # Search through board names for now
    boards = BulletinBoard.list_boards()

    boards
    |> Enum.map(fn board ->
      content = "#{board.name} #{board.description || ""}"
      score = calculate_score(content, terms, [], [])

      if score > 0 do
        %{
          type: :bulletin,
          title: board.name,
          selector: "/bulletin/#{board.id}",
          snippet: board.description || "(no description)",
          score: score
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Score calculation with phrase and exclusion support
  defp calculate_score(content, terms, phrases, exclude) do
    content_lower = String.downcase(content)

    # Check exclusions first
    has_excluded = Enum.any?(exclude, &String.contains?(content_lower, &1))
    if has_excluded do
      0
    else
      # Score for individual terms
      term_score = Enum.reduce(terms, 0, fn term, acc ->
        matches = content_lower
          |> String.split(term)
          |> length()
          |> Kernel.-(1)
        acc + matches
      end)

      # Bonus for phrase matches
      phrase_score = Enum.reduce(phrases, 0, fn phrase, acc ->
        if String.contains?(content_lower, phrase) do
          acc + 10
        else
          acc
        end
      end)

      term_score + phrase_score
    end
  end

  defp filter_by_date(items, nil, nil, _field), do: items
  defp filter_by_date(items, since, until_date, field) do
    Enum.filter(items, fn item ->
      date = Map.get(item, field)
      after_since = is_nil(since) or (date && date >= since)
      before_until = is_nil(until_date) or (date && date <= until_date)
      after_since and before_until
    end)
  end

  defp extract_snippet(content, terms) do
    content_lower = String.downcase(content)

    # Find first matching term
    first_match = terms
      |> Enum.map(fn term ->
        case :binary.match(content_lower, term) do
          {pos, _} -> pos
          :nomatch -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> 0 end)

    # Extract around match
    start = max(0, first_match - 30)
    String.slice(content, start, 100)
    |> String.trim()
    |> then(fn s -> if start > 0, do: "..." <> s, else: s end)
    |> then(fn s -> if String.length(content) > start + 100, do: s <> "...", else: s end)
  end
end
