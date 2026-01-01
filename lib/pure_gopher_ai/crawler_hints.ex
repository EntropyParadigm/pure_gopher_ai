defmodule PureGopherAi.CrawlerHints do
  @moduledoc """
  Crawler optimization for Gopher search engines like Veronica-2.

  Provides:
  - robots.txt equivalent for Gopher
  - Sitemap generation for crawlers
  - Meta information for indexing
  - Crawl hints and priorities

  Note: While Gopher doesn't have a formal robots.txt standard,
  many crawlers respect similar conventions. Veronica-2 crawls
  based on gophermap links and respects reasonable crawl etiquette.
  """

  alias PureGopherAi.Config
  alias PureGopherAi.UserPhlog
  alias PureGopherAi.UserProfiles
  alias PureGopherAi.BulletinBoard

  @doc """
  Generates a robots.txt file for Gopher crawlers.

  While not standard, some crawlers respect this.
  """
  def robots_txt do
    """
    # Gopher Robots.txt for PureGopherAI
    # Contact: #{Config.admin_email()}

    User-agent: *
    # Welcome! We encourage indexing of public content.

    # Allow all public content
    Allow: /
    Allow: /phlog
    Allow: /users
    Allow: /guestbook
    Allow: /bulletin
    Allow: /files
    Allow: /servers
    Allow: /about
    Allow: /search

    # Disallow private/authenticated areas
    Disallow: /mail
    Disallow: /admin
    Disallow: /bookmarks
    Disallow: /export
    Disallow: /api

    # Disallow session-specific paths
    Disallow: /chat
    Disallow: /clear

    # Crawl-delay in seconds (be polite)
    Crawl-delay: 2

    # Sitemap location
    Sitemap: /sitemap.txt
    """
  end

  @doc """
  Generates a text-based sitemap for crawlers.

  Lists all public selectors with optional metadata.
  """
  def sitemap_txt(host, port) do
    base = "gopher://#{host}#{if port == 70, do: "", else: ":#{port}"}"

    static_paths = [
      {"/", "Main Menu", :high},
      {"/about", "About This Server", :medium},
      {"/phlog", "Server Phlog", :high},
      {"/phlog/feed", "Phlog Atom Feed", :low},
      {"/users", "User Profiles", :high},
      {"/guestbook", "Guestbook", :medium},
      {"/bulletin", "Bulletin Board", :medium},
      {"/files", "File Archive", :medium},
      {"/servers", "Gopherspace Directory", :medium},
      {"/search", "Search", :medium},
      {"/caps.txt", "Server Capabilities", :low},
      {"/art", "ASCII Art Generator", :low}
    ]

    # Get dynamic content
    user_paths = get_user_paths()
    phlog_paths = get_phlog_paths()
    bulletin_paths = get_bulletin_paths()

    all_paths = static_paths ++ user_paths ++ phlog_paths ++ bulletin_paths

    header = """
    # PureGopherAI Sitemap
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    # Total URLs: #{length(all_paths)}
    #
    # Format: URL | Title | Priority (high/medium/low)
    #
    """

    entries = all_paths
      |> Enum.sort_by(fn {_, _, priority} ->
        case priority do
          :high -> 0
          :medium -> 1
          :low -> 2
        end
      end)
      |> Enum.map(fn {path, title, priority} ->
        "#{base}#{path} | #{title} | #{priority}"
      end)
      |> Enum.join("\n")

    header <> entries
  end

  @doc """
  Generates a gophermap-style sitemap (more Gopher-native).
  """
  def sitemap_gophermap(host, port) do
    base_lines = [
      "i",
      "i    ╔═══════════════════════════════════════════════════════╗",
      "i    ║              SITEMAP / CRAWLER INDEX                  ║",
      "i    ╚═══════════════════════════════════════════════════════╝",
      "i",
      "i    This page lists all public content for search indexing.",
      "i    Last updated: #{DateTime.utc_now() |> DateTime.to_iso8601()}",
      "i",
      "i════════════════════════════════════════════════════════════",
      "i   MAIN SECTIONS",
      "i════════════════════════════════════════════════════════════",
      "i",
      "1Main Menu\t/\t#{host}\t#{port}",
      "0About This Server\t/about\t#{host}\t#{port}",
      "1Server Phlog\t/phlog\t#{host}\t#{port}",
      "1User Profiles\t/users\t#{host}\t#{port}",
      "1Guestbook\t/guestbook\t#{host}\t#{port}",
      "1Bulletin Board\t/bulletin\t#{host}\t#{port}",
      "1File Archive\t/files\t#{host}\t#{port}",
      "1Gopherspace Directory\t/servers\t#{host}\t#{port}",
      "7Search\t/search\t#{host}\t#{port}",
      "i"
    ]

    # Add user phlogs section
    {:ok, authors} = UserPhlog.list_authors(limit: 100)
    user_phlog_lines =
      if length(authors) > 0 do
        header = [
          "i════════════════════════════════════════════════════════════",
          "i   USER PHLOGS (#{length(authors)} authors)",
          "i════════════════════════════════════════════════════════════",
          "i"
        ]

        user_entries = Enum.map(authors, fn author ->
          "1#{author.username}'s Phlog (#{author.count} posts)\t/phlog/user/#{author.username}\t#{host}\t#{port}"
        end)

        header ++ user_entries ++ ["i"]
      else
        []
      end

    # Add bulletin boards section
    boards = BulletinBoard.list_boards()
    board_lines =
      if length(boards) > 0 do
        header = [
          "i════════════════════════════════════════════════════════════",
          "i   BULLETIN BOARDS (#{length(boards)} boards)",
          "i════════════════════════════════════════════════════════════",
          "i"
        ]

        board_entries = Enum.map(boards, fn board ->
          "1#{board.name}\t/bulletin/#{board.id}\t#{host}\t#{port}"
        end)

        header ++ board_entries ++ ["i"]
      else
        []
      end

    footer_lines = [
      "i════════════════════════════════════════════════════════════",
      "i   MACHINE-READABLE FORMATS",
      "i════════════════════════════════════════════════════════════",
      "i",
      "0robots.txt\t/robots.txt\t#{host}\t#{port}",
      "0sitemap.txt\t/sitemap.txt\t#{host}\t#{port}",
      "0caps.txt\t/caps.txt\t#{host}\t#{port}",
      "0Phlog Atom Feed\t/phlog/feed\t#{host}\t#{port}",
      "i",
      "1Return to Main Menu\t/\t#{host}\t#{port}",
      "i"
    ]

    all_lines = base_lines ++ user_phlog_lines ++ board_lines ++ footer_lines
    Enum.join(all_lines, "\r\n") <> "\r\n.\r\n"
  end

  @doc """
  Generates meta information block for a page.

  Can be included in gophermaps to help crawlers understand content.
  """
  def meta_block(opts \\ []) do
    title = Keyword.get(opts, :title, "PureGopherAI")
    description = Keyword.get(opts, :description, "")
    keywords = Keyword.get(opts, :keywords, [])
    updated = Keyword.get(opts, :updated, DateTime.utc_now() |> DateTime.to_iso8601())

    lines = [
      "i[META]",
      "iTitle: #{title}"
    ]

    lines = if description != "" do
      lines ++ ["iDescription: #{description}"]
    else
      lines
    end

    lines = if keywords != [] do
      lines ++ ["iKeywords: #{Enum.join(keywords, ", ")}"]
    else
      lines
    end

    lines = lines ++ [
      "iUpdated: #{updated}",
      "i[/META]"
    ]

    Enum.join(lines, "\r\n")
  end

  @doc """
  Returns crawler-friendly hints for the root gophermap.
  """
  def root_hints(host, port) do
    """
    i
    i════════════════════════════════════════════════════════════
    i   FOR CRAWLERS & SEARCH ENGINES
    i════════════════════════════════════════════════════════════
    i
    0robots.txt\t/robots.txt\t#{host}\t#{port}
    1Sitemap\t/sitemap\t#{host}\t#{port}
    0caps.txt\t/caps.txt\t#{host}\t#{port}
    i
    """
  end

  # Private functions to gather dynamic content

  defp get_user_paths do
    {:ok, profiles, _} = UserProfiles.list(limit: 1000)

    Enum.flat_map(profiles, fn profile ->
      [{"/users/#{profile.username}", "User: #{profile.username}", :medium}]
    end)
  end

  defp get_phlog_paths do
    {:ok, posts} = UserPhlog.recent_posts(limit: 100)

    Enum.map(posts, fn post ->
      {"/phlog/user/#{post.username}/#{post.id}", "Phlog: #{post.title}", :medium}
    end)
  end

  defp get_bulletin_paths do
    boards = BulletinBoard.list_boards()

    Enum.map(boards, fn board ->
      {"/bulletin/#{board.id}", "Board: #{board.name}", :medium}
    end)
  end
end
