defmodule PureGopherAi.AiEngine do
  @moduledoc """
  The AI inference engine using Bumblebee for text generation.
  Loads a text generation model and provides a simple API for generating responses.
  Uses Nx.Serving for automatic request batching.
  """

  require Logger

  @doc """
  Sets up and returns an Nx.Serving for text generation.
  This serving can be started under a supervisor and will handle batching automatically.
  """
  def setup_serving do
    Logger.info("Loading AI model... This may take a moment on first run.")

    # Load GPT-2 as a lightweight default model
    # For production, consider Llama 2 or similar: Bumblebee.load_model({:hf, "meta-llama/Llama-2-7b-hf"})
    {:ok, model_info} = Bumblebee.load_model({:hf, "openai-community/gpt2"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "openai-community/gpt2"})
    {:ok, generation_config} = Bumblebee.load_generation_config({:hf, "openai-community/gpt2"})

    # Configure generation parameters
    generation_config =
      Bumblebee.configure(generation_config,
        max_new_tokens: 100,
        no_repeat_ngram_size: 2
      )

    # Create serving with batching enabled
    serving =
      Bumblebee.Text.generation(model_info, tokenizer, generation_config,
        compile: [batch_size: 4, sequence_length: 256],
        defn_options: [compiler: EXLA],
        stream: false
      )

    Logger.info("AI model loaded successfully!")
    serving
  end

  @doc """
  Generates text based on the given prompt.
  Calls the Nx.Serving process directly for low-latency inference.

  ## Examples

      iex> PureGopherAi.AiEngine.generate("Hello, world!")
      "Hello, world! I am a robot..."
  """
  def generate(prompt) when is_binary(prompt) do
    case Nx.Serving.batched_run(PureGopherAi.Serving, prompt) do
      %{results: [%{text: generated_text} | _]} ->
        generated_text

      %{results: []} ->
        "No response generated."

      error ->
        Logger.error("AI generation failed: #{inspect(error)}")
        "Error: Unable to generate response."
    end
  end
end
