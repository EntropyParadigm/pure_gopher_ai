defmodule PureGopherAi.Caps do
  @moduledoc """
  Capability discovery (CAPS.txt) support.

  Similar to Gemini's robots.txt-style capability discovery,
  this module provides a machine-readable description of
  server capabilities.

  Served at /caps.txt
  """

  alias PureGopherAi.Config

  @doc """
  Generates the CAPS.txt content for the server.
  """
  def generate do
    """
    # PureGopherAI Server Capabilities
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    #{server_info()}

    #{protocol_support()}

    #{features()}

    #{api_info()}

    #{rate_limits()}

    #{content_types()}
    """
  end

  @doc """
  Returns a map of all capabilities for programmatic access.
  """
  def capabilities do
    %{
      server: %{
        name: "PureGopherAI",
        version: version(),
        description: "AI-powered Gopher server with community features"
      },
      protocols: %{
        gopher: true,
        gopher_plus: true,
        gemini: Config.gemini_enabled?(),
        tor: Config.tor_enabled?()
      },
      features: feature_list(),
      api: %{
        tokens: true,
        webhooks: true,
        federation: true
      },
      limits: %{
        max_request_size: 1024,
        max_response_size: 10_485_760,  # 10MB
        rate_limit_requests: 60,
        rate_limit_window_seconds: 60
      }
    }
  end

  # Private functions

  defp server_info do
    """
    [Server]
    Name: PureGopherAI
    Version: #{version()}
    Description: AI-powered Gopher server with community features
    Admin: #{Config.admin_email()}
    Software: Elixir/OTP
    """
  end

  defp protocol_support do
    gemini = if Config.gemini_enabled?(), do: "yes", else: "no"
    tor = if Config.tor_enabled?(), do: "yes", else: "no"

    """
    [Protocols]
    Gopher: yes
    GopherPlus: yes
    Gemini: #{gemini}
    Tor: #{tor}
    """
  end

  defp features do
    features = feature_list()
      |> Enum.map(fn {name, enabled} ->
        status = if enabled, do: "yes", else: "no"
        "#{name}: #{status}"
      end)
      |> Enum.join("\n")

    """
    [Features]
    #{features}
    """
  end

  defp feature_list do
    [
      {"AI-Chat", true},
      {"AI-Summarization", true},
      {"AI-Translation", true},
      {"User-Profiles", true},
      {"User-Phlog", true},
      {"Private-Messaging", true},
      {"Bookmarks", true},
      {"Guestbook", true},
      {"Bulletin-Board", true},
      {"Search", true},
      {"RSS-Feeds", true},
      {"Two-Factor-Auth", true},
      {"API-Tokens", true},
      {"Reactions", true},
      {"Tags", true},
      {"Comments", true},
      {"Follows", true},
      {"Trending", true},
      {"Federation", true},
      {"Webhooks", true},
      {"Backup-Restore", true},
      {"Plugins", true}
    ]
  end

  defp api_info do
    """
    [API]
    Tokens: yes
    Token-Endpoint: /api/tokens
    Webhook-Endpoint: /api/webhooks
    Federation-Endpoint: /api/federation
    Export-Endpoint: /export
    """
  end

  defp rate_limits do
    """
    [Limits]
    Max-Request-Size: 1024
    Max-Response-Size: 10485760
    Rate-Limit: 60/minute
    AI-Rate-Limit: 10/minute
    Post-Rate-Limit: 1/hour
    """
  end

  defp content_types do
    """
    [Content-Types]
    Gopher-Menu: 1
    Text: 0
    Binary: 9
    Image: I, g
    Search: 7
    HTML: h

    [Selectors]
    Root: /
    AI-Chat: /chat, /ask
    Phlog: /phlog
    Users: /users
    Search: /search
    Guestbook: /guestbook
    Bulletin: /bulletin
    Files: /files
    Caps: /caps.txt
    Feed: /phlog/feed
    """
  end

  defp version do
    case :application.get_key(:pure_gopher_ai, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "1.0.0"
    end
  end
end
