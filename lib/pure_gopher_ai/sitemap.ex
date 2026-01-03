defmodule PureGopherAi.Sitemap do
  @moduledoc """
  Generates a full sitemap/index of all available server endpoints.

  Features:
  - Complete listing of all selectors
  - Organized by category
  - Machine-readable and human-readable formats
  """

  @doc """
  Returns a list of all available selectors organized by category.
  """
  def all_selectors do
    [
      %{
        category: "AI Services",
        items: [
          %{selector: "/ask", type: 7, description: "Ask AI a question (single query)"},
          %{selector: "/chat", type: 7, description: "Chat with AI (with memory)"},
          %{selector: "/clear", type: 0, description: "Clear conversation history"},
          %{selector: "/personas", type: 1, description: "Browse AI personas"}
        ]
      },
      %{
        category: "AI Tools",
        items: [
          %{selector: "/code", type: 1, description: "Code Assistant"},
          %{selector: "/weather", type: 7, description: "Weather lookup"},
          %{selector: "/digest", type: 0, description: "Daily AI digest"},
          %{selector: "/topics", type: 0, description: "Topic discovery"},
          %{selector: "/discover", type: 7, description: "Content recommendations"},
          %{selector: "/explain", type: 7, description: "Explain a term"},
          %{selector: "/translate", type: 1, description: "Translation service"},
          %{selector: "/fetch", type: 1, description: "Gopher proxy"}
        ]
      },
      %{
        category: "Content",
        items: [
          %{selector: "/search", type: 7, description: "Search content"},
          %{selector: "/docs", type: 1, description: "Document knowledge base"},
          %{selector: "/docs/list", type: 1, description: "List documents"},
          %{selector: "/docs/ask", type: 7, description: "Query documents with RAG"},
          %{selector: "/phlog", type: 1, description: "Phlog (blog)"},
          %{selector: "/phlog/feed", type: 0, description: "Atom feed"},
          %{selector: "/phlog/users", type: 1, description: "User phlog authors"},
          %{selector: "/phlog/recent", type: 1, description: "Recent user posts"},
          %{selector: "/feeds", type: 1, description: "RSS/Atom feeds"},
          %{selector: "/art", type: 1, description: "ASCII art generator"},
          %{selector: "/files", type: 1, description: "Browse files"}
        ]
      },
      %{
        category: "Community",
        items: [
          %{selector: "/guestbook", type: 1, description: "Guestbook"},
          %{selector: "/adventure", type: 1, description: "Text adventure game"},
          %{selector: "/fortune", type: 1, description: "Fortune & quotes"},
          %{selector: "/links", type: 1, description: "Link directory"},
          %{selector: "/board", type: 1, description: "Bulletin board"},
          %{selector: "/paste", type: 1, description: "Pastebin"},
          %{selector: "/polls", type: 1, description: "Polls & voting"},
          %{selector: "/users", type: 1, description: "User profiles"},
          %{selector: "/calendar", type: 1, description: "Calendar & events"},
          %{selector: "/short", type: 1, description: "URL shortener"},
          %{selector: "/utils", type: 1, description: "Quick utilities"},
          %{selector: "/mail", type: 1, description: "Mailbox / Private messaging"},
          %{selector: "/trivia", type: 1, description: "Trivia quiz game"},
          %{selector: "/bookmarks", type: 1, description: "Bookmarks / Favorites"},
          %{selector: "/games", type: 1, description: "Simple games (Hangman, Number Guess, Word Scramble)"}
        ]
      },
      %{
        category: "Utilities",
        items: [
          %{selector: "/utils/dice", type: 7, description: "Roll dice"},
          %{selector: "/utils/8ball", type: 7, description: "Magic 8-Ball"},
          %{selector: "/utils/coin", type: 0, description: "Flip a coin"},
          %{selector: "/utils/random", type: 7, description: "Random number"},
          %{selector: "/utils/pick", type: 7, description: "Random item picker"},
          %{selector: "/utils/uuid", type: 0, description: "Generate UUID"},
          %{selector: "/utils/password", type: 0, description: "Generate password"},
          %{selector: "/utils/hash", type: 7, description: "Calculate hash"},
          %{selector: "/utils/base64/encode", type: 7, description: "Base64 encode"},
          %{selector: "/utils/base64/decode", type: 7, description: "Base64 decode"},
          %{selector: "/utils/rot13", type: 7, description: "ROT13 cipher"},
          %{selector: "/utils/timestamp", type: 7, description: "Convert timestamp"},
          %{selector: "/utils/now", type: 0, description: "Current timestamp"},
          %{selector: "/utils/count", type: 7, description: "Count text"},
          %{selector: "/convert", type: 7, description: "Unit converter"},
          %{selector: "/calc", type: 7, description: "Calculator"}
        ]
      },
      %{
        category: "Server",
        items: [
          %{selector: "/", type: 1, description: "Home / root menu"},
          %{selector: "/about", type: 0, description: "About this server"},
          %{selector: "/stats", type: 0, description: "Server statistics"},
          %{selector: "/health", type: 0, description: "Health check"},
          %{selector: "/sitemap", type: 1, description: "Full sitemap (this page)"}
        ]
      }
    ]
  end

  @doc """
  Returns a flat list of all selectors for easy iteration.
  """
  def flat_selectors do
    all_selectors()
    |> Enum.flat_map(fn cat ->
      Enum.map(cat.items, &Map.put(&1, :category, cat.category))
    end)
  end

  @doc """
  Returns the total count of all selectors.
  """
  def count do
    flat_selectors() |> length()
  end

  @doc """
  Returns a list of categories.
  """
  def categories do
    all_selectors()
    |> Enum.map(& &1.category)
  end

  @doc """
  Returns statistics about the sitemap.
  """
  def stats do
    selectors = all_selectors()

    type_counts = selectors
      |> Enum.flat_map(& &1.items)
      |> Enum.group_by(& &1.type)
      |> Enum.map(fn {type, items} -> {type, length(items)} end)
      |> Enum.into(%{})

    %{
      total_selectors: count(),
      total_categories: length(selectors),
      menus: Map.get(type_counts, 1, 0),
      documents: Map.get(type_counts, 0, 0),
      search_queries: Map.get(type_counts, 7, 0)
    }
  end

  @doc """
  Returns selectors matching a search query.
  """
  def search(query) when is_binary(query) do
    query_lower = String.downcase(query)

    flat_selectors()
    |> Enum.filter(fn item ->
      String.contains?(String.downcase(item.description), query_lower) or
      String.contains?(String.downcase(item.selector), query_lower) or
      String.contains?(String.downcase(item.category), query_lower)
    end)
  end

  @doc """
  Returns selectors by category.
  """
  def by_category(category) when is_binary(category) do
    category_lower = String.downcase(category)

    case Enum.find(all_selectors(), fn cat ->
           String.downcase(cat.category) == category_lower
         end) do
      nil -> {:error, :not_found}
      cat -> {:ok, cat}
    end
  end

  @doc """
  Returns selectors by type.
  Type 0 = documents, Type 1 = menus, Type 7 = search/query
  """
  def by_type(type) when type in [0, 1, 7] do
    flat_selectors()
    |> Enum.filter(& &1.type == type)
  end

  def by_type(_), do: []

  @doc """
  Generates a plain text version of the sitemap.
  """
  def to_text do
    all_selectors()
    |> Enum.map(fn cat ->
      items = cat.items
        |> Enum.map(fn item ->
          type_str = case item.type do
            0 -> "[DOC]"
            1 -> "[DIR]"
            7 -> "[QRY]"
            _ -> "[???]"
          end
          "  #{type_str} #{item.selector}\n        #{item.description}"
        end)
        |> Enum.join("\n")

      "=== #{cat.category} ===\n#{items}"
    end)
    |> Enum.join("\n\n")
  end
end
