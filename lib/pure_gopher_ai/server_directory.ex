defmodule PureGopherAi.ServerDirectory do
  @moduledoc """
  Directory of major Gopherspace servers and hubs.

  Provides links to the broader Gopherspace community including:
  - Major hubs (Floodgap, SDF, etc.)
  - Search engines (Veronica-2)
  - Phlog communities
  - Public access servers
  """

  @doc """
  Returns the list of major Gopherspace servers organized by category.
  """
  def servers do
    %{
      hubs: [
        %{
          name: "Floodgap Systems",
          host: "gopher.floodgap.com",
          port: 70,
          selector: "/",
          description: "The Gopher Project - Major hub and Veronica-2 home"
        },
        %{
          name: "SDF Public Access Unix",
          host: "sdf.org",
          port: 70,
          selector: "/",
          description: "Free public access Unix system with Gopher hosting"
        },
        %{
          name: "Quux.org",
          host: "gopher.quux.org",
          port: 70,
          selector: "/",
          description: "Historic Gopher archive and resources"
        },
        %{
          name: "Circumlunar Space",
          host: "circumlunar.space",
          port: 70,
          selector: "/",
          description: "Gemini and Gopher community hub"
        }
      ],
      search: [
        %{
          name: "Veronica-2",
          host: "gopher.floodgap.com",
          port: 70,
          selector: "/v2",
          description: "Primary Gopherspace search engine"
        },
        %{
          name: "Veronica-2 Registration",
          host: "gopher.floodgap.com",
          port: 70,
          selector: "/v2/register",
          description: "Register your server for indexing"
        },
        %{
          name: "GopherVR Search",
          host: "gophervr.com",
          port: 70,
          selector: "/",
          description: "Alternative Gopher search"
        }
      ],
      community: [
        %{
          name: "Gopher Club",
          host: "gopher.club",
          port: 70,
          selector: "/",
          description: "Phlog community and aggregator"
        },
        %{
          name: "Republic of Zaibatsu",
          host: "zaibatsu.circumlunar.space",
          port: 70,
          selector: "/",
          description: "Tildeverse Gopher community"
        },
        %{
          name: "Cosmic Voyage",
          host: "cosmic.voyage",
          port: 70,
          selector: "/",
          description: "Collaborative science fiction universe"
        },
        %{
          name: "tilde.team",
          host: "tilde.team",
          port: 70,
          selector: "/",
          description: "Tildeverse community with Gopher"
        }
      ],
      pubnix: [
        %{
          name: "RTC (Raw Text Club)",
          host: "rawtext.club",
          port: 70,
          selector: "/",
          description: "Minimalist public access system"
        },
        %{
          name: "tilde.town",
          host: "tilde.town",
          port: 70,
          selector: "/",
          description: "Intentional digital community"
        },
        %{
          name: "Ctrl-C Club",
          host: "ctrl-c.club",
          port: 70,
          selector: "/",
          description: "Public access Unix with Gopher"
        }
      ],
      resources: [
        %{
          name: "Gopher Protocol RFC 1436",
          host: "gopher.floodgap.com",
          port: 70,
          selector: "/gopher/tech/rfc1436.txt",
          description: "The original Gopher protocol specification"
        },
        %{
          name: "Gopher+ Specification",
          host: "gopher.floodgap.com",
          port: 70,
          selector: "/gopher/gp",
          description: "Gopher+ extended protocol documentation"
        },
        %{
          name: "Overbite Project",
          host: "gopher.floodgap.com",
          port: 70,
          selector: "/overbite",
          description: "Gopher clients and browser extensions"
        }
      ]
    }
  end

  @doc """
  Generates a gophermap for the server directory.
  """
  def generate_gophermap(host, port) do
    lines = [
      "i",
      "i    ╔═══════════════════════════════════════════════════════╗",
      "i    ║           GOPHERSPACE SERVER DIRECTORY                ║",
      "i    ╚═══════════════════════════════════════════════════════╝",
      "i",
      "i    Welcome to the wider Gopherspace! These are the major",
      "i    hubs, communities, and resources in the Gopher network.",
      "i",
      "i════════════════════════════════════════════════════════════",
      "i   MAJOR HUBS",
      "i════════════════════════════════════════════════════════════"
    ]

    lines = lines ++ format_category(servers().hubs)

    lines = lines ++ [
      "i",
      "i════════════════════════════════════════════════════════════",
      "i   SEARCH ENGINES",
      "i════════════════════════════════════════════════════════════"
    ]

    lines = lines ++ format_category(servers().search)

    lines = lines ++ [
      "i",
      "i════════════════════════════════════════════════════════════",
      "i   PHLOG COMMUNITIES",
      "i════════════════════════════════════════════════════════════"
    ]

    lines = lines ++ format_category(servers().community)

    lines = lines ++ [
      "i",
      "i════════════════════════════════════════════════════════════",
      "i   PUBLIC ACCESS UNIX (PUBNIX)",
      "i════════════════════════════════════════════════════════════"
    ]

    lines = lines ++ format_category(servers().pubnix)

    lines = lines ++ [
      "i",
      "i════════════════════════════════════════════════════════════",
      "i   DOCUMENTATION & RESOURCES",
      "i════════════════════════════════════════════════════════════"
    ]

    lines = lines ++ format_category(servers().resources)

    lines = lines ++ [
      "i",
      "i════════════════════════════════════════════════════════════",
      "i   GETTING LISTED",
      "i════════════════════════════════════════════════════════════",
      "i",
      "i   To get your Gopher server indexed by Veronica-2:",
      "i   1. Visit the registration link above",
      "i   2. Submit your server hostname and port",
      "i   3. Veronica will crawl and index your content",
      "i",
      "i   Tips for better indexing:",
      "i   - Use descriptive titles in your gophermaps",
      "i   - Keep content organized in clear directories",
      "i   - Update content regularly",
      "i   - Link to other Gopher servers",
      "i",
      "1Return to Main Menu\t/\t#{host}\t#{port}",
      "i"
    ]

    Enum.join(lines, "\r\n") <> "\r\n.\r\n"
  end

  defp format_category(servers) do
    Enum.flat_map(servers, fn server ->
      port_str = if server.port == 70, do: "", else: ":#{server.port}"
      [
        "i",
        "1#{server.name}\t#{server.selector}\t#{server.host}\t#{server.port}",
        "i    #{server.description}",
        "i    → gopher://#{server.host}#{port_str}#{server.selector}"
      ]
    end)
  end

  @doc """
  Returns a list of servers for a specific category.
  """
  def get_category(category) when is_atom(category) do
    Map.get(servers(), category, [])
  end

  @doc """
  Returns all servers as a flat list.
  """
  def all_servers do
    servers()
    |> Map.values()
    |> List.flatten()
  end
end
