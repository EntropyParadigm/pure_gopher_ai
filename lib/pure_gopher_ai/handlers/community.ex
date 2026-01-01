defmodule PureGopherAi.Handlers.Community do
  @moduledoc """
  Community feature handlers for Gopher protocol.

  Handles community-oriented features:
  - Pastebin (/paste)
  - Polls (/polls)
  - User Profiles (/users)
  - Guestbook (/guestbook)
  - Mailbox (/mail)
  - Trivia (/trivia)
  - Bookmarks (/bookmarks)
  - User Phlog (/phlog/user/)
  - Bulletin Board (/board)
  - Link Directory (/links)
  """

  require Logger

  alias PureGopherAi.Handlers.Shared
  alias PureGopherAi.Pastebin
  alias PureGopherAi.Polls
  alias PureGopherAi.UserProfiles
  alias PureGopherAi.Guestbook
  # Additional aliases for future handlers:
  # alias PureGopherAi.Mailbox
  # alias PureGopherAi.Trivia
  # alias PureGopherAi.Bookmarks
  # alias PureGopherAi.UserPhlog
  # alias PureGopherAi.BulletinBoard
  # alias PureGopherAi.LinkDirectory

  # === Pastebin Handlers ===

  @doc """
  Pastebin main menu.
  """
  def paste_menu(host, port) do
    %{active_pastes: active, total_views: views} = Pastebin.stats()

    [
      Shared.info_line("=== Pastebin ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Share text snippets with the Gopher community.", host, port),
      Shared.info_line("Pastes expire after 1 week by default.", host, port),
      Shared.info_line("", host, port),
      Shared.search_line("Create New Paste", "/paste/new", host, port),
      Shared.link_line("Recent Pastes", "/paste/recent", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- Stats ---", host, port),
      Shared.info_line("Active pastes: #{active}", host, port),
      Shared.info_line("Total views: #{views}", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- Format ---", host, port),
      Shared.info_line("To create a paste, enter your text.", host, port),
      Shared.info_line("Optional: Start with \"title: Your Title\" on first line.", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Home", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Prompt for creating a new paste.
  """
  def paste_new_prompt(host, port) do
    [
      Shared.info_line("=== Create New Paste ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter your text below.", host, port),
      Shared.info_line("Optional: Start with \"title: Your Title\"", host, port),
      Shared.info_line("Max size: #{div(Pastebin.max_size(), 1000)}KB", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle paste creation.
  """
  def handle_paste_create(content, ip, host, port) do
    # Parse optional title from first line
    {title, body} = case String.split(content, "\n", parts: 2) do
      [first_line, rest] ->
        case Regex.run(~r/^title:\s*(.+)$/i, String.trim(first_line)) do
          [_, title] -> {title, rest}
          nil -> {nil, content}
        end
      _ -> {nil, content}
    end

    opts = if title, do: [title: title], else: []

    case Pastebin.create(body, ip, opts) do
      {:ok, id} ->
        [
          Shared.info_line("=== Paste Created! ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Paste ID: #{id}", host, port),
          Shared.info_line("", host, port),
          Shared.text_link("View Paste", "/paste/#{id}", host, port),
          Shared.text_link("Raw Text", "/paste/raw/#{id}", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Share this link: gopher://#{host}:#{port}/0/paste/#{id}", host, port),
          Shared.info_line("", host, port),
          Shared.search_line("Create Another", "/paste/new", host, port),
          Shared.link_line("Back to Pastebin", "/paste", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, :too_large} ->
        Shared.error_response("Paste too large. Maximum size is #{div(Pastebin.max_size(), 1000)}KB.")

      {:error, :empty_content} ->
        Shared.error_response("Cannot create empty paste.")

      {:error, reason} ->
        Shared.error_response("Failed to create paste: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  List recent pastes.
  """
  def paste_recent(host, port) do
    case Pastebin.list_recent(20) do
      {:ok, pastes} when pastes == [] ->
        Shared.format_text_response("""
        === Recent Pastes ===

        No pastes yet. Be the first to create one!
        """, host, port)

      {:ok, pastes} ->
        paste_lines = pastes
          |> Enum.map(fn p ->
            title = p.title || "Untitled"
            created = String.slice(p.created_at, 0, 10)
            Shared.text_link("[#{created}] #{title} (#{p.lines} lines, #{p.views} views)", "/paste/#{p.id}", host, port)
          end)

        [
          Shared.info_line("=== Recent Pastes ===", host, port),
          Shared.info_line("", host, port),
          paste_lines,
          Shared.info_line("", host, port),
          Shared.search_line("Create New Paste", "/paste/new", host, port),
          Shared.link_line("Back to Pastebin", "/paste", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Shared.error_response("Failed to list pastes: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  View a paste.
  """
  def paste_view(id, host, port) do
    case Pastebin.get(id) do
      {:ok, paste} ->
        title = paste.title || "Untitled Paste"
        created = String.slice(paste.created_at, 0, 19) |> String.replace("T", " ")
        expires = String.slice(paste.expires_at, 0, 10)

        Shared.format_text_response("""
        === #{title} ===

        ID: #{paste.id}
        Syntax: #{paste.syntax}
        Size: #{paste.size} bytes (#{paste.lines} lines)
        Created: #{created}
        Expires: #{expires}
        Views: #{paste.views}

        ========== Content ==========

        #{paste.content}

        =============================

        Raw: gopher://#{host}:#{port}/0/paste/raw/#{id}
        """, host, port)

      {:error, :not_found} ->
        Shared.error_response("Paste not found.")

      {:error, :expired} ->
        Shared.error_response("This paste has expired.")

      {:error, reason} ->
        Shared.error_response("Failed to get paste: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  Get raw paste content.
  """
  def paste_raw(id) do
    case Pastebin.get_raw(id) do
      {:ok, content} ->
        content <> "\r\n"

      {:error, :not_found} ->
        "Error: Paste not found.\r\n"

      {:error, :expired} ->
        "Error: This paste has expired.\r\n"

      {:error, _} ->
        "Error: Failed to retrieve paste.\r\n"
    end
  end

  # === Polls Handlers ===

  @doc """
  Polls main menu.
  """
  def polls_menu(host, port) do
    %{active_polls: active, total_votes: votes} = Polls.stats()

    [
      Shared.info_line("=== Community Polls ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Vote on community polls and create your own!", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Active Polls", "/polls/active", host, port),
      Shared.link_line("Closed Polls", "/polls/closed", host, port),
      Shared.search_line("Create New Poll", "/polls/new", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("--- Stats ---", host, port),
      Shared.info_line("Active polls: #{active}", host, port),
      Shared.info_line("Total votes cast: #{votes}", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Home", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Prompt for creating a new poll.
  """
  def polls_new_prompt(host, port) do
    [
      Shared.info_line("=== Create New Poll ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Format: Question | Option1 | Option2 | Option3 ...", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Example:", host, port),
      Shared.info_line("What's your favorite protocol? | Gopher | Gemini | HTTP | All of them", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Minimum 2 options, maximum 10.", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle poll creation.
  """
  def handle_polls_create(input, ip, host, port) do
    parts = String.split(input, "|") |> Enum.map(&String.trim/1)

    case parts do
      [question | options] when length(options) >= 2 ->
        case Polls.create(question, options, ip) do
          {:ok, poll} ->
            [
              Shared.info_line("=== Poll Created! ===", host, port),
              Shared.info_line("", host, port),
              Shared.info_line("Question: #{poll.question}", host, port),
              Shared.info_line("Options: #{length(poll.options)}", host, port),
              Shared.info_line("", host, port),
              Shared.link_line("View Your Poll", "/polls/#{poll.id}", host, port),
              Shared.link_line("Back to Polls", "/polls", host, port),
              ".\r\n"
            ]
            |> IO.iodata_to_binary()

          {:error, reason} ->
            Shared.error_response("Failed to create poll: #{Shared.sanitize_error(reason)}")
        end

      _ ->
        Shared.error_response("Invalid format. Use: Question | Option1 | Option2 | ...")
    end
  end

  @doc """
  List active polls.
  """
  def polls_active(host, port) do
    case Polls.list_active() do
      {:ok, polls} when polls == [] ->
        Shared.format_text_response("""
        === Active Polls ===

        No active polls. Create one!
        """, host, port)

      {:ok, polls} ->
        poll_lines = polls
          |> Enum.map(fn p ->
            votes = Enum.sum(p.votes)
            Shared.link_line("#{p.question} (#{votes} votes)", "/polls/#{p.id}", host, port)
          end)

        [
          Shared.info_line("=== Active Polls ===", host, port),
          Shared.info_line("", host, port),
          poll_lines,
          Shared.info_line("", host, port),
          Shared.search_line("Create New Poll", "/polls/new", host, port),
          Shared.link_line("Back to Polls", "/polls", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Shared.error_response("Failed to list polls: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  List closed polls.
  """
  def polls_closed(host, port) do
    case Polls.list_closed() do
      {:ok, polls} when polls == [] ->
        Shared.format_text_response("""
        === Closed Polls ===

        No closed polls yet.
        """, host, port)

      {:ok, polls} ->
        poll_lines = polls
          |> Enum.map(fn p ->
            votes = Enum.sum(p.votes)
            Shared.link_line("#{p.question} (#{votes} votes)", "/polls/#{p.id}", host, port)
          end)

        [
          Shared.info_line("=== Closed Polls ===", host, port),
          Shared.info_line("", host, port),
          poll_lines,
          Shared.info_line("", host, port),
          Shared.link_line("Back to Polls", "/polls", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Shared.error_response("Failed to list polls: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  View a poll.
  """
  def polls_view(id, ip, host, port) do
    case Polls.get(id) do
      {:ok, poll} ->
        total_votes = Enum.sum(poll.votes)
        has_voted = Polls.has_voted?(id, ip)

        option_lines =
          poll.options
          |> Enum.with_index()
          |> Enum.map(fn {opt, idx} ->
            votes = Enum.at(poll.votes, idx, 0)
            percent = if total_votes > 0, do: Float.round(votes / total_votes * 100, 1), else: 0.0

            if poll.status == :active and not has_voted do
              Shared.link_line("[ ] #{opt} (#{votes} - #{percent}%)", "/polls/vote/#{id}/#{idx}", host, port)
            else
              Shared.info_line("[#{votes}] #{opt} (#{percent}%)", host, port)
            end
          end)

        status_line = case poll.status do
          :active -> if has_voted, do: "You have already voted.", else: "Click an option to vote!"
          :closed -> "This poll has closed."
        end

        [
          Shared.info_line("=== #{poll.question} ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Total votes: #{total_votes}", host, port),
          Shared.info_line("Status: #{poll.status}", host, port),
          Shared.info_line(status_line, host, port),
          Shared.info_line("", host, port),
          option_lines,
          Shared.info_line("", host, port),
          Shared.link_line("Back to Polls", "/polls", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, :not_found} ->
        Shared.error_response("Poll not found.")

      {:error, reason} ->
        Shared.error_response("Failed to get poll: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  Handle poll vote.
  """
  def handle_polls_vote(rest, ip, host, port) do
    case String.split(rest, "/", parts: 2) do
      [poll_id, option_idx_str] ->
        case Integer.parse(option_idx_str) do
          {option_idx, ""} ->
            case Polls.vote(poll_id, option_idx, ip) do
              :ok ->
                polls_view(poll_id, ip, host, port)

              {:error, :already_voted} ->
                Shared.error_response("You have already voted on this poll.")

              {:error, :poll_closed} ->
                Shared.error_response("This poll has closed.")

              {:error, :invalid_option} ->
                Shared.error_response("Invalid option.")

              {:error, reason} ->
                Shared.error_response("Failed to vote: #{Shared.sanitize_error(reason)}")
            end

          _ ->
            Shared.error_response("Invalid option number.")
        end

      _ ->
        Shared.error_response("Invalid vote path.")
    end
  end

  # === Guestbook Handlers ===

  @doc """
  Guestbook page with pagination.
  """
  def guestbook_page(host, port, page) do
    result = Guestbook.list_entries(page: page, per_page: 20)
    case result do
      %{entries: _entries} = result ->
        entries_text = if Enum.empty?(result.entries) do
          [Shared.info_line("No entries yet. Be the first to sign!", host, port)]
        else
          result.entries
          |> Enum.map(fn entry ->
            date = format_date(entry.created_at)
            message = String.slice(entry.message, 0, 200)
            message = if String.length(entry.message) > 200, do: message <> "...", else: message

            [
              Shared.info_line("--- #{entry.name} (#{date}) ---", host, port),
              message
              |> String.split("\n")
              |> Enum.map(&Shared.info_line(&1, host, port)),
              Shared.info_line("", host, port)
            ]
          end)
        end

        nav = []
        nav = if result.page > 1, do: [Shared.link_line("Previous Page", "/guestbook/page/#{result.page - 1}", host, port) | nav], else: nav
        nav = if result.page < result.total_pages, do: [Shared.link_line("Next Page", "/guestbook/page/#{result.page + 1}", host, port) | nav], else: nav

        [
          Shared.info_line("=== Guestbook ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Page #{result.page} of #{result.total_pages} (#{result.total} entries)", host, port),
          Shared.info_line("", host, port),
          Shared.search_line("Sign the Guestbook", "/guestbook/sign", host, port),
          Shared.info_line("", host, port),
          entries_text,
          nav,
          Shared.info_line("", host, port),
          Shared.link_line("Back to Home", "/", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()
    end
  end

  @doc """
  Prompt for signing the guestbook.
  """
  def guestbook_sign_prompt(host, port) do
    [
      Shared.info_line("=== Sign the Guestbook ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Format: Your Name | Your Message", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Example: Alice | Hello from the Gopher hole!", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle guestbook signing.
  """
  def handle_guestbook_sign(input, host, port, ip) do
    case String.split(input, "|", parts: 2) do
      [name, message] ->
        name = String.trim(name)
        message = String.trim(message)

        case Guestbook.sign(name, message, ip) do
          {:ok, _entry} ->
            [
              Shared.info_line("=== Thank You! ===", host, port),
              Shared.info_line("", host, port),
              Shared.info_line("Your entry has been added to the guestbook.", host, port),
              Shared.info_line("", host, port),
              Shared.link_line("View Guestbook", "/guestbook", host, port),
              Shared.link_line("Back to Home", "/", host, port),
              ".\r\n"
            ]
            |> IO.iodata_to_binary()

          {:error, :empty_name} ->
            Shared.error_response("Please provide your name.")

          {:error, :empty_message} ->
            Shared.error_response("Please provide a message.")

          {:error, :rate_limited} ->
            Shared.error_response("Please wait before signing again.")

          {:error, reason} ->
            Shared.error_response("Failed to sign guestbook: #{Shared.sanitize_error(reason)}")
        end

      _ ->
        Shared.error_response("Invalid format. Use: Your Name | Your Message")
    end
  end

  # === User Profiles Handlers ===

  @doc """
  User profiles menu.
  """
  def users_menu(host, port) do
    [
      Shared.info_line("=== User Profiles ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Create your Gopher identity!", host, port),
      Shared.info_line("", host, port),
      Shared.search_line("Create Profile", "/users/create", host, port),
      Shared.search_line("Search Users", "/users/search", host, port),
      Shared.link_line("Browse Users", "/users/list", host, port),
      Shared.info_line("", host, port),
      Shared.link_line("Back to Home", "/", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Prompt for creating a user profile.
  """
  def users_create_prompt(host, port) do
    [
      Shared.info_line("=== Create Profile ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Format: username | passphrase | bio (optional)", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Username: 3-20 chars, alphanumeric + underscore", host, port),
      Shared.info_line("Passphrase: 8+ chars (for editing your profile)", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Example: alice | my secret phrase | Hello, I'm Alice!", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle user creation.
  """
  def handle_users_create(input, ip, host, port) do
    parts = String.split(input, "|") |> Enum.map(&String.trim/1)

    {username, passphrase, bio} = case parts do
      [u, p, b] -> {u, p, b}
      [u, p] -> {u, p, nil}
      _ -> {nil, nil, nil}
    end

    if username && passphrase do
      case UserProfiles.create(username, passphrase, ip, bio: bio) do
        {:ok, profile} ->
          [
            Shared.info_line("=== Profile Created! ===", host, port),
            Shared.info_line("", host, port),
            Shared.info_line("Username: ~#{profile.username}", host, port),
            Shared.info_line("", host, port),
            Shared.info_line("IMPORTANT: Remember your passphrase!", host, port),
            Shared.info_line("You'll need it to edit your profile and write posts.", host, port),
            Shared.info_line("", host, port),
            Shared.link_line("View Your Profile", "/users/~#{profile.username}", host, port),
            Shared.link_line("Back to Users", "/users", host, port),
            ".\r\n"
          ]
          |> IO.iodata_to_binary()

        {:error, reason} ->
          Shared.error_response("Failed to create profile: #{Shared.sanitize_error(reason)}")
      end
    else
      Shared.error_response("Invalid format. Use: username | passphrase | bio (optional)")
    end
  end

  @doc """
  Search users prompt.
  """
  def users_search_prompt(host, port) do
    [
      Shared.info_line("=== Search Users ===", host, port),
      Shared.info_line("", host, port),
      Shared.info_line("Enter a username to search for:", host, port),
      ".\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Handle user search.
  """
  def handle_users_search(query, host, port) do
    case UserProfiles.search(query) do
      {:ok, []} ->
        Shared.format_text_response("""
        === Search Results ===

        No users found matching "#{query}".
        """, host, port)

      {:ok, users} ->
        user_lines = users
          |> Enum.map(fn u ->
            Shared.link_line("~#{u.username}", "/users/~#{u.username}", host, port)
          end)

        [
          Shared.info_line("=== Search Results ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Found #{length(users)} user(s):", host, port),
          Shared.info_line("", host, port),
          user_lines,
          Shared.info_line("", host, port),
          Shared.search_line("Search Again", "/users/search", host, port),
          Shared.link_line("Back to Users", "/users", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Shared.error_response("Failed to search: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  List users with pagination.
  """
  def users_list(host, port, page) do
    case UserProfiles.list(page: page, per_page: 25) do
      {:ok, result} ->
        user_lines = if Enum.empty?(result.profiles) do
          [Shared.info_line("No users yet. Be the first to create a profile!", host, port)]
        else
          result.profiles
          |> Enum.map(fn u ->
            Shared.link_line("~#{u.username}", "/users/~#{u.username}", host, port)
          end)
        end

        nav = []
        nav = if result.page > 1, do: [Shared.link_line("Previous", "/users/list/page/#{result.page - 1}", host, port) | nav], else: nav
        nav = if result.page < result.total_pages, do: [Shared.link_line("Next", "/users/list/page/#{result.page + 1}", host, port) | nav], else: nav

        [
          Shared.info_line("=== User Directory ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Page #{result.page} of #{result.total_pages}", host, port),
          Shared.info_line("", host, port),
          user_lines,
          Shared.info_line("", host, port),
          nav,
          Shared.search_line("Search Users", "/users/search", host, port),
          Shared.link_line("Back to Users", "/users", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Shared.error_response("Failed to list users: #{Shared.sanitize_error(reason)}")
    end
  end

  @doc """
  View a user profile.
  """
  def users_view(username, host, port) do
    case UserProfiles.get(username) do
      {:ok, profile} ->
        bio = profile.bio || "No bio set."
        created = format_date(profile.created_at)

        [
          Shared.info_line("=== ~#{profile.username} ===", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("Member since: #{created}", host, port),
          Shared.info_line("", host, port),
          Shared.info_line("--- Bio ---", host, port),
          bio
          |> String.split("\n")
          |> Enum.map(&Shared.info_line(&1, host, port)),
          Shared.info_line("", host, port),
          Shared.link_line("User's Phlog", "/phlog/user/#{username}", host, port),
          Shared.info_line("", host, port),
          Shared.link_line("Back to Users", "/users", host, port),
          ".\r\n"
        ]
        |> IO.iodata_to_binary()

      {:error, :not_found} ->
        Shared.error_response("User not found.")

      {:error, reason} ->
        Shared.error_response("Failed to get profile: #{Shared.sanitize_error(reason)}")
    end
  end

  # === Helper Functions ===

  defp format_date(nil), do: "Unknown"
  defp format_date(datetime) when is_binary(datetime) do
    String.slice(datetime, 0, 10)
  end
  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d")
  end
  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d")
  end
  defp format_date(_), do: "Unknown"
end
