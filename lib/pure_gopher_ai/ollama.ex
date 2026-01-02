defmodule PureGopherAi.Ollama do
  @moduledoc """
  Ollama API integration for AI text generation.

  Uses Ollama's local API for high-quality language models.
  Falls back to Bumblebee if Ollama is unavailable.

  ## Configuration

      config :pure_gopher_ai,
        ollama_enabled: true,
        ollama_url: "http://localhost:11434",
        ollama_model: "llama3.2",
        ollama_timeout: 120_000

  ## Supported Models

  Any model available in your Ollama installation:
  - llama3.2, llama3.1 (Meta's latest)
  - mistral, mixtral (Mistral AI)
  - qwen2.5 (Alibaba)
  - phi3 (Microsoft)
  - gemma2 (Google)
  """

  require Logger

  @default_url "http://localhost:11434"
  @default_model "llama3.2"
  @default_timeout 120_000

  @doc """
  Check if Ollama is enabled and available.
  """
  def enabled? do
    Application.get_env(:pure_gopher_ai, :ollama_enabled, false)
  end

  @doc """
  Check if Ollama server is reachable.
  """
  def available? do
    url = get_url()

    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {~c"#{url}/api/tags", []}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  end

  @doc """
  Generate text using Ollama.
  Returns {:ok, response} or {:error, reason}.
  """
  def generate(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, get_model())
    system = Keyword.get(opts, :system)

    body = build_request_body(prompt, model, system, false)

    case do_request("/api/generate", body) do
      {:ok, %{"response" => response}} ->
        {:ok, String.trim(response)}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate text with streaming, calling callback for each chunk.
  Returns {:ok, full_response} or {:error, reason}.
  """
  def generate_stream(prompt, callback, opts \\ []) do
    model = Keyword.get(opts, :model, get_model())
    system = Keyword.get(opts, :system)

    body = build_request_body(prompt, model, system, true)

    case do_streaming_request("/api/generate", body, callback) do
      {:ok, full_response} ->
        {:ok, String.trim(full_response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Chat completion with message history.
  Messages format: [%{role: "user", content: "..."}, %{role: "assistant", content: "..."}]
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, get_model())
    system = Keyword.get(opts, :system)

    body = build_chat_body(messages, model, system, false)

    case do_request("/api/chat", body) do
      {:ok, %{"message" => %{"content" => content}}} ->
        {:ok, String.trim(content)}

      {:ok, %{"error" => error}} ->
        {:error, error}

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

    body = build_chat_body(messages, model, system, true)

    case do_streaming_request("/api/chat", body, callback) do
      {:ok, full_response} ->
        {:ok, String.trim(full_response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List available models in Ollama.
  """
  def list_models do
    case do_request("/api/tags", nil, :get) do
      {:ok, %{"models" => models}} ->
        {:ok, Enum.map(models, fn m ->
          %{
            name: m["name"],
            size: format_size(m["size"]),
            modified: m["modified_at"]
          }
        end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp get_url do
    Application.get_env(:pure_gopher_ai, :ollama_url, @default_url)
  end

  defp get_model do
    Application.get_env(:pure_gopher_ai, :ollama_model, @default_model)
  end

  defp get_timeout do
    Application.get_env(:pure_gopher_ai, :ollama_timeout, @default_timeout)
  end

  defp build_request_body(prompt, model, system, stream) do
    base = %{
      "model" => model,
      "prompt" => prompt,
      "stream" => stream
    }

    if system do
      Map.put(base, "system", system)
    else
      base
    end
  end

  defp build_chat_body(messages, model, system, stream) do
    formatted_messages = Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg[:role] || msg["role"]),
        "content" => msg[:content] || msg["content"]
      }
    end)

    # Add system message at the beginning if provided
    all_messages = if system do
      [%{"role" => "system", "content" => system} | formatted_messages]
    else
      formatted_messages
    end

    %{
      "model" => model,
      "messages" => all_messages,
      "stream" => stream
    }
  end

  defp do_request(path, body, method \\ :post) do
    url = get_url() <> path
    timeout = get_timeout()

    :inets.start()
    :ssl.start()

    request = case method do
      :get ->
        {~c"#{url}", []}

      :post ->
        json_body = Jason.encode!(body)
        {~c"#{url}", [], ~c"application/json", json_body}
    end

    case :httpc.request(method, request, [{:timeout, timeout}], []) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        case Jason.decode(to_string(response_body)) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, {{_, status, _}, _, response_body}} ->
        Logger.warning("Ollama request failed: #{status} - #{response_body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("Ollama connection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_streaming_request(path, body, callback) do
    url = get_url() <> path
    timeout = get_timeout()

    :inets.start()
    :ssl.start()

    json_body = Jason.encode!(body)

    # Use sync streaming via httpc
    case :httpc.request(
      :post,
      {~c"#{url}", [], ~c"application/json", json_body},
      [{:timeout, timeout}],
      [{:sync, false}, {:stream, :self}]
    ) do
      {:ok, request_id} ->
        collect_stream_response(request_id, callback, "")

      {:error, reason} ->
        Logger.warning("Ollama streaming request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp collect_stream_response(request_id, callback, acc) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        collect_stream_response(request_id, callback, acc)

      {:http, {^request_id, :stream, chunk}} ->
        # Parse NDJSON chunks
        chunk_str = to_string(chunk)

        new_acc = chunk_str
        |> String.split("\n", trim: true)
        |> Enum.reduce(acc, fn line, inner_acc ->
          case Jason.decode(line) do
            {:ok, %{"response" => text}} when is_binary(text) ->
              callback.(text)
              inner_acc <> text

            {:ok, %{"message" => %{"content" => text}}} when is_binary(text) ->
              callback.(text)
              inner_acc <> text

            _ ->
              inner_acc
          end
        end)

        collect_stream_response(request_id, callback, new_acc)

      {:http, {^request_id, :stream_end, _headers}} ->
        {:ok, acc}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, reason}
    after
      get_timeout() ->
        :httpc.cancel_request(request_id)
        {:error, :timeout}
    end
  end

  defp format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)}GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)}MB"
      true -> "#{bytes}B"
    end
  end
  defp format_size(_), do: "unknown"
end
