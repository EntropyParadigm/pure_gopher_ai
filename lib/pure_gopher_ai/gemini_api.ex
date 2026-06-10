defmodule PureGopherAi.GeminiApi do
  @moduledoc """
  Google Gemini Flash 2.5 HTTP API client.

  Used as the AI backend on Raspberry Pi (where local ML is infeasible).
  Communicates with Google's Generative AI API via Finch HTTP client.

  ## Configuration

      config :pure_gopher_ai,
        ai_backend: :gemini_api,
        gemini_api_key: System.get_env("GEMINI_API_KEY"),
        gemini_model: "gemini-2.5-flash",
        gemini_timeout: 120_000

  ## API Reference

  Uses the `generateContent` endpoint:
  https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
  """

  require Logger

  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @default_model "gemini-2.5-flash"
  @default_timeout 120_000

  @doc """
  Check if the Gemini API is configured (API key is present).
  """
  def enabled? do
    api_key() != nil && api_key() != ""
  end

  @doc """
  Check if the Gemini API is reachable.
  """
  def available? do
    if not enabled?() do
      false
    else
      url = "#{@base_url}/models?key=#{api_key()}"

      case Finch.build(:get, url) |> Finch.request(PureGopherAi.Finch, receive_timeout: 5_000) do
        {:ok, %Finch.Response{status: 200}} -> true
        _ -> false
      end
    end
  end

  @doc """
  Generate text using Gemini API.
  Returns `{:ok, response}` or `{:error, reason}`.

  ## Options

    * `:system` - System instruction text
    * `:model` - Override model name
  """
  def generate(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, get_model())
    system = Keyword.get(opts, :system)

    body = build_generate_body(prompt, system)
    url = "#{@base_url}/models/#{model}:generateContent?key=#{api_key()}"

    case do_post(url, body) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        text = extract_text(parts)
        {:ok, String.trim(text)}

      {:ok, %{"error" => %{"message" => message}}} ->
        {:error, message}

      {:ok, %{"candidates" => []}} ->
        {:error, :no_candidates}

      {:ok, unexpected} ->
        Logger.warning("Gemini API unexpected response: #{inspect(unexpected)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate text with streaming, calling callback for each chunk.
  Returns `{:ok, full_response}` or `{:error, reason}`.

  Uses the `streamGenerateContent` endpoint with SSE.
  """
  def generate_stream(prompt, callback, opts \\ []) do
    model = Keyword.get(opts, :model, get_model())
    system = Keyword.get(opts, :system)

    body = build_generate_body(prompt, system)
    url = "#{@base_url}/models/#{model}:streamGenerateContent?alt=sse&key=#{api_key()}"

    do_streaming_post(url, body, callback)
  end

  @doc """
  Chat completion with message history.

  Messages format: `[%{role: "user", content: "..."}, %{role: "assistant", content: "..."}]`

  Gemini uses `"user"` and `"model"` roles (not `"assistant"`).
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, get_model())
    system = Keyword.get(opts, :system)

    body = build_chat_body(messages, system)
    url = "#{@base_url}/models/#{model}:generateContent?key=#{api_key()}"

    case do_post(url, body) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        text = extract_text(parts)
        {:ok, String.trim(text)}

      {:ok, %{"error" => %{"message" => message}}} ->
        {:error, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Chat with streaming.
  """
  def chat_stream(messages, callback, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, get_model())
    system = Keyword.get(opts, :system)

    body = build_chat_body(messages, system)
    url = "#{@base_url}/models/#{model}:streamGenerateContent?alt=sse&key=#{api_key()}"

    do_streaming_post(url, body, callback)
  end

  @doc """
  List available models (returns static info for the configured model).
  """
  def list_models do
    model = get_model()

    {:ok,
     [
       %{
         name: model,
         size: "cloud",
         modified: "N/A"
       }
     ]}
  end

  # --- Private Functions ---

  defp api_key do
    Application.get_env(:pure_gopher_ai, :gemini_api_key)
  end

  defp get_model do
    Application.get_env(:pure_gopher_ai, :gemini_model, @default_model)
  end

  defp get_timeout do
    Application.get_env(:pure_gopher_ai, :gemini_timeout, @default_timeout)
  end

  defp build_generate_body(prompt, system) do
    body = %{
      "contents" => [
        %{
          "role" => "user",
          "parts" => [%{"text" => prompt}]
        }
      ]
    }

    if system && system != "" do
      Map.put(body, "systemInstruction", %{
        "parts" => [%{"text" => system}]
      })
    else
      body
    end
  end

  defp build_chat_body(messages, system) do
    contents =
      Enum.map(messages, fn msg ->
        role = to_string(msg[:role] || msg["role"])

        # Gemini uses "model" instead of "assistant"
        gemini_role =
          case role do
            "assistant" -> "model"
            other -> other
          end

        content = msg[:content] || msg["content"]

        %{
          "role" => gemini_role,
          "parts" => [%{"text" => content}]
        }
      end)

    body = %{"contents" => contents}

    if system && system != "" do
      Map.put(body, "systemInstruction", %{
        "parts" => [%{"text" => system}]
      })
    else
      body
    end
  end

  defp extract_text(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp do_post(url, body) do
    json_body = Jason.encode!(body)
    timeout = get_timeout()

    request =
      Finch.build(:post, url, [{"content-type", "application/json"}], json_body)

    case Finch.request(request, PureGopherAi.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        Jason.decode(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning("Gemini API error: HTTP #{status} - #{String.slice(response_body, 0..200)}")

        case Jason.decode(response_body) do
          {:ok, %{"error" => %{"message" => message}}} -> {:error, message}
          _ -> {:error, {:http_error, status}}
        end

      {:error, reason} ->
        Logger.warning("Gemini API connection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_streaming_post(url, body, callback) do
    json_body = Jason.encode!(body)
    timeout = get_timeout()

    request =
      Finch.build(:post, url, [{"content-type", "application/json"}], json_body)

    # Collect SSE chunks. Gemini sends events separated by blank lines.
    # Normalize \r\n to \n so splitting works regardless of line ending style.
    acc = %{buffer: "", full_response: ""}

    result =
      Finch.stream(request, PureGopherAi.Finch, acc, fn
        {:status, status}, acc ->
          Map.put(acc, :status, status)

        {:headers, _headers}, acc ->
          acc

        {:data, data}, acc ->
          # Normalize line endings and append to buffer
          normalized = String.replace(data, "\r\n", "\n")
          buffer = acc.buffer <> normalized

          # Split on double-newline (SSE event boundary)
          # The last element may be incomplete — keep it in the buffer
          parts = String.split(buffer, "\n\n")
          {events, [remainder]} = Enum.split(parts, -1)

          new_full =
            Enum.reduce(events, acc.full_response, fn event, full ->
              event
              |> String.split("\n", trim: true)
              |> Enum.reduce(full, fn line, inner_full ->
                case parse_sse_line(line) do
                  {:ok, text} ->
                    callback.(text)
                    inner_full <> text

                  _ ->
                    inner_full
                end
              end)
            end)

          %{acc | buffer: remainder, full_response: new_full}
      end,
      receive_timeout: timeout
      )

    case result do
      {:ok, final_acc} ->
        # Parse any remaining buffer content (last event may not end with \n\n)
        remaining_text =
          final_acc.buffer
          |> String.split("\n", trim: true)
          |> Enum.reduce("", fn line, text_acc ->
            case parse_sse_line(line) do
              {:ok, text} ->
                callback.(text)
                text_acc <> text

              _ ->
                text_acc
            end
          end)

        {:ok, String.trim(final_acc.full_response <> remaining_text)}

      {:error, reason} ->
        Logger.warning("Gemini streaming failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_sse_line("data: " <> json_str) do
    case Jason.decode(String.trim(json_str)) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        text = extract_text(parts)
        if text != "", do: {:ok, text}, else: :skip

      {:ok, _} ->
        :skip

      {:error, _} ->
        :incomplete
    end
  end

  defp parse_sse_line(_), do: :skip
end
