defmodule PureGopherAi.ModelRegistry do
  @moduledoc """
  Registry for managing multiple AI models.
  Supports lazy loading of models on first request.
  Each model gets its own Nx.Serving process.
  """

  use GenServer
  require Logger

  @table_name :model_registry

  # Model configurations - Bumblebee-compatible models only
  # Supported architectures (2026): Llama, Mistral, Gemma, GPT-2, GPT-Neo, Phi, Flan-T5
  @models %{
    # Default lightweight model - TinyLlama (Llama-based)
    "tinyllama" => %{
      name: "TinyLlama",
      repo: "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
      description: "Fast, high-quality chat (1.1B params)",
      default: true
    },
    # Phi-2 - Microsoft, optimized for edge/low-latency
    "phi2" => %{
      name: "Phi-2",
      repo: "microsoft/phi-2",
      description: "Excellent reasoning, code capable (2.7B params)",
      default: false
    },
    # Gemma - Google's lightweight model
    "gemma" => %{
      name: "Gemma 2B",
      repo: "google/gemma-2b-it",
      description: "Google's efficient instruction model (2B params)",
      default: false
    },
    # Mistral - High quality open model
    "mistral" => %{
      name: "Mistral 7B Instruct",
      repo: "mistralai/Mistral-7B-Instruct-v0.2",
      description: "High quality instruction model (7B params)",
      default: false
    },
    # GPT-2 variants - reliable, fast fallbacks
    "gpt2" => %{
      name: "GPT-2",
      repo: "openai-community/gpt2",
      description: "Fast, lightweight (124M params)",
      default: false
    },
    "gpt2-medium" => %{
      name: "GPT-2 Medium",
      repo: "openai-community/gpt2-medium",
      description: "Balanced speed/quality (355M params)",
      default: false
    },
    "gpt2-large" => %{
      name: "GPT-2 Large",
      repo: "openai-community/gpt2-large",
      description: "Higher quality (774M params)",
      default: false
    },
    # Flan-T5 - instruction-following
    "flan-t5" => %{
      name: "Flan-T5 Base",
      repo: "google/flan-t5-base",
      description: "Instruction-following (250M params)",
      default: false
    }
  }

  # Client API

  @doc """
  Starts the model registry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lists all available models.
  Returns a list of {model_id, model_info} tuples.
  """
  def list_models do
    @models
    |> Enum.map(fn {id, info} ->
      loaded = is_loaded?(id)
      {id, Map.put(info, :loaded, loaded)}
    end)
    |> Enum.sort_by(fn {_id, info} -> !info.default end)
  end

  @doc """
  Gets the default model ID.
  """
  def default_model do
    @models
    |> Enum.find(fn {_id, info} -> info.default end)
    |> case do
      {id, _info} -> id
      nil -> "gpt2"
    end
  end

  @doc """
  Gets info about a specific model.
  """
  def get_model(model_id) do
    Map.get(@models, model_id)
  end

  @doc """
  Checks if a model exists.
  """
  def exists?(model_id) do
    Map.has_key?(@models, model_id)
  end

  @doc """
  Checks if a model is currently loaded.
  """
  def is_loaded?(model_id) do
    case :ets.lookup(@table_name, model_id) do
      [{^model_id, :loaded}] -> true
      _ -> false
    end
  end

  @doc """
  Ensures a model is loaded, loading it if necessary.
  Returns :ok or {:error, reason}.
  """
  def ensure_loaded(model_id) do
    if is_loaded?(model_id) do
      :ok
    else
      GenServer.call(__MODULE__, {:load_model, model_id}, :infinity)
    end
  end

  @doc """
  Gets the serving name for a model.
  """
  def serving_name(model_id) do
    String.to_atom("model_serving_#{model_id}")
  end

  @doc """
  Generates text using a specific model.
  Loads the model if not already loaded.
  """
  def generate(model_id, prompt, context \\ nil) do
    case ensure_loaded(model_id) do
      :ok ->
        full_prompt = build_prompt(prompt, context)
        streaming = Application.get_env(:pure_gopher_ai, :streaming_enabled, true)

        if streaming do
          stream = Nx.Serving.batched_run(serving_name(model_id), full_prompt)
          collect_stream(stream, full_prompt)
        else
          case Nx.Serving.batched_run(serving_name(model_id), full_prompt) do
            %{results: [%{text: text} | _]} -> clean_response(text, full_prompt)
            _ -> "No response generated."
          end
        end

      {:error, reason} ->
        "Error loading model: #{inspect(reason)}"
    end
  end

  @doc """
  Generates text with streaming callback.
  """
  def generate_stream(model_id, prompt, context, callback) do
    case ensure_loaded(model_id) do
      :ok ->
        full_prompt = build_prompt(prompt, context)
        streaming = Application.get_env(:pure_gopher_ai, :streaming_enabled, true)

        if streaming do
          stream = Nx.Serving.batched_run(serving_name(model_id), full_prompt)
          stream_with_callback(stream, full_prompt, callback)
        else
          response = generate(model_id, prompt, context)
          callback.(response)
          response
        end

      {:error, reason} ->
        error = "Error loading model: #{inspect(reason)}"
        callback.(error)
        error
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set])
    Logger.info("ModelRegistry started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:load_model, model_id}, _from, state) do
    result = do_load_model(model_id)
    {:reply, result, state}
  end

  # Private functions

  defp do_load_model(model_id) do
    case Map.get(@models, model_id) do
      nil ->
        {:error, :unknown_model}

      model_info ->
        Logger.info("Loading model: #{model_info.name} (#{model_info.repo})")

        try do
          {:ok, model_info_loaded} = Bumblebee.load_model({:hf, model_info.repo})
          {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_info.repo})
          {:ok, generation_config} = Bumblebee.load_generation_config({:hf, model_info.repo})

          generation_config =
            Bumblebee.configure(generation_config,
              max_new_tokens: 100
            )

          streaming = Application.get_env(:pure_gopher_ai, :streaming_enabled, true)

          serving =
            Bumblebee.Text.generation(model_info_loaded, tokenizer, generation_config,
              compile: [batch_size: 1, sequence_length: 256],
              defn_options: [compiler: EXLA],
              stream: streaming,
              stream_done: streaming
            )

          # Start the serving under the application supervisor
          serving_name = serving_name(model_id)

          child_spec =
            Supervisor.child_spec(
              {Nx.Serving, serving: serving, name: serving_name, batch_size: 1, batch_timeout: 100},
              id: serving_name
            )

          case DynamicSupervisor.start_child(PureGopherAi.ModelSupervisor, child_spec) do
            {:ok, _pid} ->
              :ets.insert(@table_name, {model_id, :loaded})
              Logger.info("Model loaded successfully: #{model_info.name}")
              :ok

            {:error, {:already_started, _pid}} ->
              :ets.insert(@table_name, {model_id, :loaded})
              :ok

            {:error, reason} ->
              Logger.error("Failed to start serving for #{model_id}: #{inspect(reason)}")
              {:error, reason}
          end
        rescue
          e ->
            Logger.error("Failed to load model #{model_id}: #{inspect(e)}")
            {:error, e}
        end
    end
  end

  defp build_prompt(prompt, context) do
    if context && context != "" do
      "#{context}\nUser: #{prompt}\nAssistant:"
    else
      prompt
    end
  end

  defp collect_stream(stream, full_prompt) do
    chunks =
      stream
      |> Enum.reduce([], fn
        {:done, _result}, acc -> acc
        chunk, acc -> [chunk | acc]
      end)
      |> Enum.reverse()
      |> Enum.join("")

    clean_response(chunks, full_prompt)
  end

  defp stream_with_callback(stream, full_prompt, callback) do
    prompt_len = String.length(full_prompt)

    {_, chunks} =
      Enum.reduce(stream, {0, []}, fn
        {:done, _result}, acc ->
          acc

        chunk, {pos, acc} when is_binary(chunk) ->
          new_pos = pos + String.length(chunk)

          if pos >= prompt_len do
            callback.(chunk)
            {new_pos, [chunk | acc]}
          else
            overlap = prompt_len - pos
            if String.length(chunk) > overlap do
              new_chunk = String.slice(chunk, overlap..-1//1)
              callback.(new_chunk)
              {new_pos, [new_chunk | acc]}
            else
              {new_pos, acc}
            end
          end

        _other, acc ->
          acc
      end)

    chunks
    |> Enum.reverse()
    |> Enum.join("")
  end

  defp clean_response(text, prompt) do
    text
    |> String.replace_prefix(prompt, "")
    |> String.trim()
    |> case do
      "" -> "No response generated."
      response -> response
    end
  end
end
