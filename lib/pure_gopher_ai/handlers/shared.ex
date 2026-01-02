defmodule PureGopherAi.Handlers.Shared do
  @moduledoc """
  Shared utilities for Gopher protocol handlers.

  Provides common formatting, error handling, and response generation
  functions used across all handler modules.
  """

  alias PureGopherAi.InputSanitizer
  alias PureGopherAi.OutputSanitizer

  # === Response Formatting (using iodata for performance) ===

  @doc """
  Format text as Gopher info lines with proper escaping.
  Returns iodata for zero-copy socket sends.
  """
  def format_text_response(text, host, port) do
    lines =
      text
      |> InputSanitizer.escape_gopher()
      |> String.split("\r\n")
      |> Enum.map(&[?i, &1, ?\t, ?\t, host, ?\t, Integer.to_string(port), "\r\n"])

    [lines, ".\r\n"]
  end

  @doc """
  Format a list of lines as Gopher info lines.
  Returns iodata for zero-copy socket sends.
  """
  def format_gopher_lines(lines, host, port) do
    Enum.map(lines, fn line ->
      escaped = InputSanitizer.escape_gopher(line)
      [?i, escaped, ?\t, ?\t, host, ?\t, Integer.to_string(port), "\r\n"]
    end)
  end

  @doc """
  Format a Gopher menu item.
  Returns iodata.
  """
  def menu_item(type, text, selector, host, port) do
    [type, text, ?\t, selector, ?\t, host, ?\t, Integer.to_string(port), "\r\n"]
  end

  @doc """
  Format an info line (type i).
  """
  def info_line(text, host, port) do
    menu_item(?i, text, "", host, port)
  end

  @doc """
  Format a link line (type 1 for directory).
  """
  def link_line(text, selector, host, port) do
    menu_item(?1, text, selector, host, port)
  end

  @doc """
  Format a text file link (type 0).
  """
  def text_link(text, selector, host, port) do
    menu_item(?0, text, selector, host, port)
  end

  @doc """
  Format a search/input line (type 7).
  """
  def search_line(text, selector, host, port) do
    menu_item(?7, text, selector, host, port)
  end

  # === Error Responses ===

  @doc """
  Generate a Gopher error response (type 3).
  """
  def error_response(message) do
    ["3", message, "\t\terror.host\t1\r\n.\r\n"]
  end

  @doc """
  Sanitize internal error reasons for user-facing messages.
  Prevents leaking internal implementation details.
  """
  def sanitize_error(reason) do
    case reason do
      # File/IO errors
      :enoent -> "File not found"
      :eacces -> "Permission denied"
      :eisdir -> "Path is a directory"
      :enotdir -> "Not a directory"
      :enomem -> "Insufficient memory"
      :enospc -> "No space left on device"

      # Network errors
      :timeout -> "Request timed out"
      :closed -> "Connection closed"
      :econnrefused -> "Connection refused"
      :ehostunreach -> "Host unreachable"
      :enetunreach -> "Network unreachable"
      {:connect_failed, _} -> "Connection failed"
      {:send_failed, _} -> "Send failed"
      {:recv_failed, _} -> "Receive failed"

      # Application-specific errors
      :not_found -> "Not found"
      :invalid_input -> "Invalid input"
      :empty_content -> "Content cannot be empty"
      :no_response -> "AI could not generate a response"
      :unknown_error -> "An unexpected error occurred"
      :rate_limited -> "Rate limit exceeded"
      :already_exists -> "Already exists"
      :already_ingested -> "Already processed"
      :path_not_allowed -> "Path not allowed"
      :invalid_host -> "Invalid host"
      :invalid_url -> "Invalid URL"
      :file_not_found -> "File not found"
      :content_blocked -> "Content not allowed"
      {:content_blocked, _} -> "Content not allowed"
      :question_too_long -> "Question too long"
      :option_too_long -> "Option too long"
      :empty_question -> "Question cannot be empty"
      :empty_option -> "Option cannot be empty"
      :title_too_long -> "Title too long"
      :body_too_long -> "Content too long"
      :empty_title -> "Title cannot be empty"
      :empty_body -> "Content cannot be empty"
      :invalid_credentials -> "Invalid credentials"
      :unauthorized -> "Unauthorized"
      :poll_closed -> "Poll has closed"
      :already_voted -> "Already voted"
      :invalid_option -> "Invalid option"
      :recipient_not_found -> "Recipient not found"
      :recipient_inbox_full -> "Recipient inbox full"
      :passphrase_too_short -> "Passphrase too short"
      :invalid_username -> "Invalid username"
      :username_taken -> "Username already taken"
      :post_limit_reached -> "Post limit reached"

      # Tuple errors - extract message if available
      {:error, inner} -> sanitize_error(inner)
      {atom, _detail} when is_atom(atom) -> sanitize_error(atom)

      # Unknown errors - generic message
      _ -> "An error occurred"
    end
  end

  @doc """
  Generate rate limit response.
  """
  def rate_limit_response(retry_after_ms) do
    retry_seconds = div(retry_after_ms, 1000) + 1
    ["3Rate limit exceeded. Please wait ", Integer.to_string(retry_seconds), " seconds.\t\terror.host\t1\r\n.\r\n"]
  end

  @doc """
  Generate banned IP response.
  """
  def banned_response do
    "3Access denied. Your IP has been banned.\t\terror.host\t1\r\n.\r\n"
  end

  @doc """
  Generate blocklisted IP response.
  """
  def blocklisted_response do
    "3Access denied. Your IP is on a public blocklist.\t\terror.host\t1\r\n.\r\n"
  end

  # === Streaming Helpers ===

  @doc """
  Stream a chunk to socket with proper formatting.
  For buffered streaming, use stream_buffered/5 instead.
  """
  def stream_chunk(socket, chunk, host, port) do
    if String.length(chunk) > 0 do
      sanitized = OutputSanitizer.sanitize(chunk)
      escaped = InputSanitizer.escape_gopher(sanitized)
      lines = String.split(escaped, "\r\n", trim: false)
      formatted = Enum.map(lines, &[?i, &1, ?\t, ?\t, host, ?\t, Integer.to_string(port), "\r\n"])
      ThousandIsland.Socket.send(socket, formatted)
    end
  end

  @doc """
  Create a buffered streamer that collects tokens and outputs proper lines.
  Returns a tuple {streamer_pid, flush_fn}.
  """
  def start_buffered_streamer(socket, host, port, opts \\ []) do
    line_width = Keyword.get(opts, :line_width, 65)

    {:ok, pid} = Agent.start_link(fn -> "" end)

    streamer = fn chunk ->
      if String.length(chunk) > 0 do
        Agent.update(pid, fn buffer ->
          new_buffer = buffer <> chunk
          # Check for natural breaks or line width
          {to_send, remaining} = flush_buffer(new_buffer, line_width)

          if to_send != "" do
            lines = String.split(to_send, "\n", trim: false)
            Enum.each(lines, fn line ->
              if String.length(String.trim(line)) > 0 do
                formatted = [?i, String.trim_trailing(line), ?\t, ?\t, host, ?\t, Integer.to_string(port), "\r\n"]
                ThousandIsland.Socket.send(socket, formatted)
              end
            end)
          end

          remaining
        end)
      end
    end

    flush = fn ->
      remaining = Agent.get(pid, & &1)
      Agent.stop(pid)

      if String.length(String.trim(remaining)) > 0 do
        lines = remaining |> String.trim() |> String.split("\n", trim: false)
        Enum.each(lines, fn line ->
          if String.length(String.trim(line)) > 0 do
            sanitized = OutputSanitizer.sanitize(line)
            escaped = InputSanitizer.escape_gopher(sanitized)
            formatted = [?i, String.trim_trailing(escaped), ?\t, ?\t, host, ?\t, Integer.to_string(port), "\r\n"]
            ThousandIsland.Socket.send(socket, formatted)
          end
        end)
      end
    end

    {streamer, flush}
  end

  # Flush buffer when we hit natural breaks or reach line width
  defp flush_buffer(buffer, line_width) do
    cond do
      # Check for newlines first
      String.contains?(buffer, "\n") ->
        [first | rest] = String.split(buffer, "\n", parts: 2)
        {first <> "\n", Enum.join(rest, "\n")}

      # Check for sentence endings followed by space when buffer is getting long
      String.length(buffer) > line_width and Regex.match?(~r/[.!?]\s+\S/, buffer) ->
        case Regex.run(~r/^(.*?[.!?])\s+(.*)$/s, buffer) do
          [_, sentence, rest] -> {sentence, rest}
          _ -> {"", buffer}
        end

      # Force break at line_width on word boundary
      String.length(buffer) > line_width + 15 ->
        words = String.split(buffer, ~r/\s+/)
        {line_words, remaining_words} = split_at_width(words, line_width)
        {Enum.join(line_words, " "), Enum.join(remaining_words, " ")}

      true ->
        {"", buffer}
    end
  end

  defp split_at_width(words, max_width) do
    split_at_width(words, max_width, [], 0)
  end

  defp split_at_width([], _max, acc, _len), do: {Enum.reverse(acc), []}
  defp split_at_width([word | rest], max, acc, len) do
    word_len = String.length(word)
    new_len = if len == 0, do: word_len, else: len + 1 + word_len

    if new_len > max and acc != [] do
      {Enum.reverse(acc), [word | rest]}
    else
      split_at_width(rest, max, [word | acc], new_len)
    end
  end

  # === IP Formatting ===

  @doc """
  Format IP address tuple to string.
  """
  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  def format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  def format_ip(ip), do: inspect(ip)

  @doc """
  Hash IP for privacy-friendly logging (first 8 chars of SHA256).
  """
  def hash_ip_for_log(ip) do
    ip_str = format_ip(ip)
    :crypto.hash(:sha256, ip_str)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  @doc """
  Generate session ID from IP (for stateful operations).
  """
  def session_id_from_ip(ip) do
    ip_str = format_ip(ip)
    :crypto.hash(:sha256, ip_str)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
