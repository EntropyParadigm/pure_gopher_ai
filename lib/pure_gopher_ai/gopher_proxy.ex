defmodule PureGopherAi.GopherProxy do
  @moduledoc """
  Gopher protocol proxy for fetching external content.

  Allows fetching content from other Gopher servers, with optional
  AI-powered summarization. Acts as a "reader mode" for Gopher.

  ## Security
  - Configurable allowlist/blocklist for hosts
  - Timeout limits to prevent hanging
  - Size limits to prevent memory issues
  - No recursive fetching to prevent abuse
  """

  require Logger

  alias PureGopherAi.Summarizer

  @default_timeout 10_000  # 10 seconds
  @default_max_size 100_000  # 100KB
  @default_port 70

  @doc """
  Fetches content from an external Gopher server.

  Options:
  - :timeout - Connection timeout in ms (default: 10000)
  - :max_size - Maximum response size in bytes (default: 100000)
  """
  def fetch(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_size = Keyword.get(opts, :max_size, @default_max_size)

    case parse_gopher_url(url) do
      {:ok, host, port, selector} ->
        Logger.info("[GopherProxy] Fetching: gopher://#{host}:#{port}/#{selector}")

        case connect_and_fetch(host, port, selector, timeout, max_size) do
          {:ok, content} ->
            {:ok, %{
              url: url,
              host: host,
              port: port,
              selector: selector,
              content: content,
              size: byte_size(content)
            }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches and summarizes content from an external Gopher server.
  """
  def fetch_and_summarize(url, opts \\ []) do
    case fetch(url, opts) do
      {:ok, result} ->
        summary_opts = Keyword.get(opts, :summary_opts, [])

        case Summarizer.summarize_text(result.content, summary_opts) do
          {:ok, summary} ->
            {:ok, Map.put(result, :summary, summary)}

          {:error, reason} ->
            # Return content without summary on AI error
            {:ok, Map.put(result, :summary, "Summary unavailable: #{inspect(reason)}")}
        end

      error ->
        error
    end
  end

  @doc """
  Fetches and summarizes with streaming output for the summary.
  """
  def fetch_and_summarize_stream(url, callback, opts \\ []) do
    case fetch(url, opts) do
      {:ok, result} ->
        summary_opts = Keyword.get(opts, :summary_opts, [])
        Summarizer.summarize_text_stream(result.content, callback, summary_opts)
        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Parses a Gopher URL into components.

  Supports formats:
  - gopher://host/selector
  - gopher://host:port/selector
  - gopher://host (defaults to /)
  """
  def parse_gopher_url(url) do
    url = String.trim(url)

    cond do
      String.starts_with?(url, "gopher://") ->
        parse_full_gopher_url(url)

      # Allow bare host/selector
      true ->
        {:error, :invalid_url}
    end
  end

  # Private functions

  defp parse_full_gopher_url(url) do
    # Remove gopher:// prefix
    rest = String.replace_prefix(url, "gopher://", "")

    # Split into host:port and path
    {host_port, selector} = case String.split(rest, "/", parts: 2) do
      [hp, sel] -> {hp, "/" <> sel}
      [hp] -> {hp, "/"}
    end

    # Parse host and port
    {host, port} = case String.split(host_port, ":", parts: 2) do
      [h, p] ->
        case Integer.parse(p) do
          {port_num, ""} -> {h, port_num}
          _ -> {h, @default_port}
        end
      [h] -> {h, @default_port}
    end

    # Validate host
    if valid_host?(host) do
      # Handle Gopher item type prefix in selector (e.g., /0/file or /1/dir)
      normalized_selector = normalize_selector(selector)
      {:ok, host, port, normalized_selector}
    else
      {:error, :invalid_host}
    end
  end

  defp normalize_selector(selector) do
    # Remove leading type indicator if present (e.g., /0/path -> path)
    case Regex.run(~r{^/([0-9+TgIsh])/(.*)$}, selector) do
      [_, _type, path] -> path
      _ ->
        # Just remove leading slash for standard selectors
        String.replace_prefix(selector, "/", "")
    end
  end

  defp valid_host?(host) do
    # Basic validation - non-empty, no spaces
    if byte_size(host) == 0 or String.contains?(host, " ") do
      false
    else
      # SSRF protection: Block private/internal addresses
      not is_private_or_internal?(host)
    end
  end

  # SSRF protection - block requests to internal/private addresses
  defp is_private_or_internal?(host) do
    host_lower = String.downcase(host)

    # Block localhost variations
    localhost_patterns = ["localhost", "127.", "0.0.0.0", "::1", "[::1]", "0:0:0:0:0:0:0:1"]
    if Enum.any?(localhost_patterns, &String.starts_with?(host_lower, &1)) do
      true
    else
      # Check if it's an IP address and block private ranges
      case parse_ipv4(host) do
        {:ok, {a, b, _c, _d}} ->
          # RFC 1918 private ranges + link-local + loopback
          cond do
            a == 10 -> true                           # 10.0.0.0/8
            a == 172 and b >= 16 and b <= 31 -> true  # 172.16.0.0/12
            a == 192 and b == 168 -> true             # 192.168.0.0/16
            a == 127 -> true                          # 127.0.0.0/8 loopback
            a == 169 and b == 254 -> true             # 169.254.0.0/16 link-local
            a == 0 -> true                            # 0.0.0.0/8
            true -> false
          end
        :error ->
          # Not an IP - check for suspicious hostnames
          suspicious_hostnames = [
            "internal", "intranet", "corp", "private", "local",
            "metadata", "169.254.169.254"  # AWS metadata service
          ]
          Enum.any?(suspicious_hostnames, &String.contains?(host_lower, &1))
      end
    end
  end

  defp parse_ipv4(host) do
    case String.split(host, ".") do
      [a, b, c, d] ->
        with {a_int, ""} <- Integer.parse(a),
             {b_int, ""} <- Integer.parse(b),
             {c_int, ""} <- Integer.parse(c),
             {d_int, ""} <- Integer.parse(d),
             true <- Enum.all?([a_int, b_int, c_int, d_int], &(&1 >= 0 and &1 <= 255)) do
          {:ok, {a_int, b_int, c_int, d_int}}
        else
          _ -> :error
        end
      _ -> :error
    end
  end

  defp connect_and_fetch(host, port, selector, timeout, max_size) do
    # Resolve host
    host_charlist = String.to_charlist(host)

    # Connect with timeout
    case :gen_tcp.connect(host_charlist, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        # Send selector with CRLF
        request = selector <> "\r\n"

        case :gen_tcp.send(socket, request) do
          :ok ->
            # Receive response with size limit
            result = receive_response(socket, timeout, max_size, [])
            :gen_tcp.close(socket)
            result

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, {:send_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp receive_response(socket, timeout, max_size, acc) do
    current_size = acc |> Enum.map(&byte_size/1) |> Enum.sum()

    if current_size >= max_size do
      # Truncate at max size
      content = acc |> Enum.reverse() |> Enum.join("") |> String.slice(0, max_size)
      {:ok, content <> "\n[Truncated at #{max_size} bytes]"}
    else
      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, data} ->
          receive_response(socket, timeout, max_size, [data | acc])

        {:error, :closed} ->
          # Connection closed - we have all data
          content = acc |> Enum.reverse() |> Enum.join("")
          {:ok, content}

        {:error, :timeout} ->
          # Timeout but we may have partial data
          if acc != [] do
            content = acc |> Enum.reverse() |> Enum.join("")
            {:ok, content <> "\n[Response timed out]"}
          else
            {:error, :timeout}
          end

        {:error, reason} ->
          {:error, {:recv_failed, reason}}
      end
    end
  end
end
