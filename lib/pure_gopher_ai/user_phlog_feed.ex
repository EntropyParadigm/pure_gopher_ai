defmodule PureGopherAi.UserPhlogFeed do
  @moduledoc """
  Generates Atom/RSS feeds for individual user phlogs.
  """

  alias PureGopherAi.UserPhlog
  alias PureGopherAi.UserProfiles
  alias PureGopherAi.Config

  @doc """
  Generates an Atom feed for a user's phlog.
  """
  def generate_atom(username, opts \\ []) do
    host = Keyword.get(opts, :host, Config.clearnet_host())
    port = Keyword.get(opts, :port, Config.clearnet_port())
    limit = Keyword.get(opts, :limit, 20)

    case UserPhlog.list_posts(username, limit: limit) do
      {:ok, [_ | _] = posts} ->
        # Get profile info
        profile = case UserProfiles.get(username) do
          {:ok, p} -> p
          _ -> %{username: username, bio: ""}
        end

        feed = build_atom_feed(profile, posts, host, port)
        {:ok, feed}

      {:ok, []} ->
        {:ok, empty_feed(username, host, port)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates an RSS 2.0 feed for a user's phlog.
  """
  def generate_rss(username, opts \\ []) do
    host = Keyword.get(opts, :host, Config.clearnet_host())
    port = Keyword.get(opts, :port, Config.clearnet_port())
    limit = Keyword.get(opts, :limit, 20)

    case UserPhlog.list_posts(username, limit: limit) do
      {:ok, [_ | _] = posts} ->
        profile = case UserProfiles.get(username) do
          {:ok, p} -> p
          _ -> %{username: username, bio: ""}
        end

        feed = build_rss_feed(profile, posts, host, port)
        {:ok, feed}

      {:ok, []} ->
        {:ok, empty_rss_feed(username, host, port)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates a combined feed for all user phlogs.
  """
  def generate_combined_atom(opts \\ []) do
    host = Keyword.get(opts, :host, Config.clearnet_host())
    port = Keyword.get(opts, :port, Config.clearnet_port())
    limit = Keyword.get(opts, :limit, 50)

    # Get all users and their posts
    {:ok, profiles, _} = UserProfiles.list(limit: 100)

    all_posts = profiles
      |> Enum.flat_map(fn profile ->
        case UserPhlog.list_posts(profile.username, limit: 10) do
          {:ok, posts} ->
            Enum.map(posts, fn post ->
              Map.put(post, :author, profile.username)
            end)
          _ ->
            []
        end
      end)
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(limit)

    feed = build_combined_atom_feed(all_posts, host, port)
    {:ok, feed}
  end

  # Atom feed builders

  defp build_atom_feed(profile, posts, host, port) do
    base_url = build_base_url(host, port)
    updated = List.first(posts).updated_at || DateTime.utc_now() |> DateTime.to_iso8601()

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>#{escape_xml(profile.username)}'s Phlog</title>
      <subtitle>#{escape_xml(profile.bio || "")}</subtitle>
      <link href="gopher://#{host}:#{port}/1/phlog/user/#{profile.username}" rel="alternate"/>
      <link href="#{base_url}/phlog/user/#{profile.username}/feed.atom" rel="self"/>
      <id>urn:gopher:#{host}:#{port}:phlog:#{profile.username}</id>
      <updated>#{updated}</updated>
      <author>
        <name>#{escape_xml(profile.username)}</name>
      </author>
      #{Enum.map(posts, &build_atom_entry(&1, profile.username, host, port)) |> Enum.join("\n")}
    </feed>
    """
  end

  defp build_atom_entry(post, username, host, port) do
    """
      <entry>
        <title>#{escape_xml(post.title)}</title>
        <link href="gopher://#{host}:#{port}/0/phlog/user/#{username}/#{post.id}"/>
        <id>urn:gopher:#{host}:#{port}:phlog:#{username}:#{post.id}</id>
        <updated>#{post.updated_at || post.created_at}</updated>
        <published>#{post.created_at}</published>
        <summary type="text">#{escape_xml(String.slice(post.body, 0, 500))}</summary>
        <content type="text">#{escape_xml(post.body)}</content>
      </entry>
    """
  end

  defp empty_feed(username, host, port) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>#{escape_xml(username)}'s Phlog</title>
      <link href="gopher://#{host}:#{port}/1/phlog/user/#{username}" rel="alternate"/>
      <id>urn:gopher:#{host}:#{port}:phlog:#{username}</id>
      <updated>#{DateTime.utc_now() |> DateTime.to_iso8601()}</updated>
    </feed>
    """
  end

  defp build_combined_atom_feed(posts, host, port) do
    base_url = build_base_url(host, port)
    updated = case List.first(posts) do
      nil -> DateTime.utc_now() |> DateTime.to_iso8601()
      post -> post.updated_at || post.created_at
    end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>All User Phlogs</title>
      <subtitle>Combined feed of all user phlog posts</subtitle>
      <link href="gopher://#{host}:#{port}/1/phlog/users" rel="alternate"/>
      <link href="#{base_url}/phlog/users/feed.atom" rel="self"/>
      <id>urn:gopher:#{host}:#{port}:phlogs:all</id>
      <updated>#{updated}</updated>
      #{Enum.map(posts, &build_combined_atom_entry(&1, host, port)) |> Enum.join("\n")}
    </feed>
    """
  end

  defp build_combined_atom_entry(post, host, port) do
    """
      <entry>
        <title>#{escape_xml(post.title)}</title>
        <link href="gopher://#{host}:#{port}/0/phlog/user/#{post.author}/#{post.id}"/>
        <id>urn:gopher:#{host}:#{port}:phlog:#{post.author}:#{post.id}</id>
        <updated>#{post.updated_at || post.created_at}</updated>
        <published>#{post.created_at}</published>
        <author>
          <name>#{escape_xml(post.author)}</name>
        </author>
        <summary type="text">#{escape_xml(String.slice(post.body, 0, 500))}</summary>
      </entry>
    """
  end

  # RSS 2.0 feed builders

  defp build_rss_feed(profile, posts, host, port) do
    pub_date = List.first(posts).created_at || DateTime.utc_now() |> DateTime.to_iso8601()

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>#{escape_xml(profile.username)}'s Phlog</title>
        <link>gopher://#{host}:#{port}/1/phlog/user/#{profile.username}</link>
        <description>#{escape_xml(profile.bio || "A gopher phlog")}</description>
        <pubDate>#{pub_date}</pubDate>
        <lastBuildDate>#{DateTime.utc_now() |> DateTime.to_iso8601()}</lastBuildDate>
        <generator>PureGopherAI</generator>
        #{Enum.map(posts, &build_rss_item(&1, profile.username, host, port)) |> Enum.join("\n")}
      </channel>
    </rss>
    """
  end

  defp build_rss_item(post, username, host, port) do
    """
        <item>
          <title>#{escape_xml(post.title)}</title>
          <link>gopher://#{host}:#{port}/0/phlog/user/#{username}/#{post.id}</link>
          <guid>urn:gopher:#{host}:#{port}:phlog:#{username}:#{post.id}</guid>
          <pubDate>#{post.created_at}</pubDate>
          <description>#{escape_xml(String.slice(post.body, 0, 500))}</description>
        </item>
    """
  end

  defp empty_rss_feed(username, host, port) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>#{escape_xml(username)}'s Phlog</title>
        <link>gopher://#{host}:#{port}/1/phlog/user/#{username}</link>
        <description>A gopher phlog</description>
        <lastBuildDate>#{DateTime.utc_now() |> DateTime.to_iso8601()}</lastBuildDate>
        <generator>PureGopherAI</generator>
      </channel>
    </rss>
    """
  end

  # Helpers

  defp build_base_url(host, port) do
    if port == 70 do
      "gopher://#{host}"
    else
      "gopher://#{host}:#{port}"
    end
  end

  defp escape_xml(nil), do: ""
  defp escape_xml(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
  defp escape_xml(other), do: escape_xml(to_string(other))
end
