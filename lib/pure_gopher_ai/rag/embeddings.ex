defmodule PureGopherAi.Rag.Embeddings do
  @moduledoc """
  Vector embeddings for RAG using Bumblebee.
  Uses a sentence transformer model for semantic similarity.
  """

  use GenServer
  require Logger

  alias PureGopherAi.Rag.DocumentStore

  # Default embedding model - small and fast
  @default_model "sentence-transformers/all-MiniLM-L6-v2"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generates an embedding for a single text.
  """
  def embed(text) when is_binary(text) do
    GenServer.call(__MODULE__, {:embed, text}, 30_000)
  end

  @doc """
  Generates embeddings for multiple texts.
  """
  def embed_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:embed_batch, texts}, 120_000)
  end

  @doc """
  Computes embeddings for all chunks that don't have them yet.
  """
  def embed_all_chunks do
    GenServer.cast(__MODULE__, :embed_all_chunks)
  end

  @doc """
  Finds the most similar chunks to a query.
  """
  def search(query, opts \\ []) do
    GenServer.call(__MODULE__, {:search, query, opts}, 30_000)
  end

  @doc """
  Returns the embedding model info.
  """
  def model_info do
    GenServer.call(__MODULE__, :model_info)
  end

  @doc """
  Checks if embeddings are enabled.
  """
  def enabled? do
    Application.get_env(:pure_gopher_ai, :rag_embeddings_enabled, true)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    if enabled?() do
      # Load embedding model asynchronously
      send(self(), :load_model)
      Logger.info("RAG Embeddings: Loading model...")
      {:ok, %{serving: nil, model_loaded: false, loading: true}}
    else
      Logger.info("RAG Embeddings: Disabled")
      {:ok, %{serving: nil, model_loaded: false, loading: false}}
    end
  end

  @impl true
  def handle_call({:embed, _text}, _from, %{serving: nil} = state) do
    {:reply, {:error, :model_not_loaded}, state}
  end

  @impl true
  def handle_call({:embed, text}, _from, %{serving: serving} = state) do
    result = do_embed(serving, text)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:embed_batch, _texts}, _from, %{serving: nil} = state) do
    {:reply, {:error, :model_not_loaded}, state}
  end

  @impl true
  def handle_call({:embed_batch, texts}, _from, %{serving: serving} = state) do
    results = Enum.map(texts, fn text -> do_embed(serving, text) end)
    {:reply, results, state}
  end

  @impl true
  def handle_call({:search, query, opts}, _from, %{serving: nil} = state) do
    # Fallback to keyword search if no embeddings
    results = keyword_search(query, opts)
    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:search, query, opts}, _from, %{serving: serving} = state) do
    top_k = Keyword.get(opts, :top_k, 5)
    threshold = Keyword.get(opts, :threshold, 0.3)

    case do_embed(serving, query) do
      {:ok, query_embedding} ->
        results = semantic_search(query_embedding, top_k, threshold)
        {:reply, {:ok, results}, state}

      {:error, _} ->
        # Fallback to keyword search
        results = keyword_search(query, opts)
        {:reply, {:ok, results}, state}
    end
  end

  @impl true
  def handle_call(:model_info, _from, state) do
    model = Application.get_env(:pure_gopher_ai, :rag_embedding_model, @default_model)
    info = %{
      model: model,
      loaded: state.model_loaded,
      loading: state.loading,
      enabled: enabled?()
    }
    {:reply, info, state}
  end

  @impl true
  def handle_cast(:embed_all_chunks, %{serving: nil} = state) do
    Logger.warning("RAG Embeddings: Cannot embed chunks - model not loaded")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:embed_all_chunks, %{serving: serving} = state) do
    Task.start(fn ->
      do_embed_all_chunks(serving)
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:load_model, state) do
    model_name = Application.get_env(:pure_gopher_ai, :rag_embedding_model, @default_model)

    case load_embedding_model(model_name) do
      {:ok, serving} ->
        Logger.info("RAG Embeddings: Model #{model_name} loaded successfully")
        # Start embedding existing chunks
        send(self(), :embed_existing_chunks)
        {:noreply, %{state | serving: serving, model_loaded: true, loading: false}}

      {:error, reason} ->
        Logger.error("RAG Embeddings: Failed to load model: #{inspect(reason)}")
        {:noreply, %{state | loading: false}}
    end
  end

  @impl true
  def handle_info(:embed_existing_chunks, %{serving: serving} = state) when serving != nil do
    Task.start(fn ->
      do_embed_all_chunks(serving)
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:embed_existing_chunks, state) do
    {:noreply, state}
  end

  # Private functions

  defp load_embedding_model(model_name) do
    try do
      {:ok, model_info} = Bumblebee.load_model({:hf, model_name})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_name})

      serving =
        Bumblebee.Text.text_embedding(model_info, tokenizer,
          compile: [batch_size: 8, sequence_length: 512],
          defn_options: [compiler: EXLA]
        )

      {:ok, serving}
    rescue
      e ->
        {:error, e}
    end
  end

  defp do_embed(serving, text) do
    try do
      %{embedding: embedding} = Nx.Serving.run(serving, text)
      {:ok, Nx.to_flat_list(embedding)}
    rescue
      e ->
        Logger.error("RAG Embeddings: Failed to embed text: #{inspect(e)}")
        {:error, e}
    end
  end

  defp do_embed_all_chunks(serving) do
    chunks = DocumentStore.all_chunks()
    |> Enum.filter(fn chunk -> chunk.embedding == nil end)

    if length(chunks) > 0 do
      Logger.info("RAG Embeddings: Embedding #{length(chunks)} chunks...")

      chunks
      |> Enum.chunk_every(10)
      |> Enum.with_index()
      |> Enum.each(fn {batch, batch_idx} ->
        Enum.each(batch, fn chunk ->
          case do_embed(serving, chunk.content) do
            {:ok, embedding} ->
              DocumentStore.update_embedding(chunk.id, embedding)

            {:error, _} ->
              :ok
          end
        end)

        if rem(batch_idx + 1, 10) == 0 do
          Logger.info("RAG Embeddings: Processed #{(batch_idx + 1) * 10} chunks...")
        end
      end)

      Logger.info("RAG Embeddings: Finished embedding #{length(chunks)} chunks")
    end
  end

  defp semantic_search(query_embedding, top_k, threshold) do
    DocumentStore.all_chunks()
    |> Enum.filter(fn chunk -> chunk.embedding != nil end)
    |> Enum.map(fn chunk ->
      similarity = cosine_similarity(query_embedding, chunk.embedding)
      {chunk, similarity}
    end)
    |> Enum.filter(fn {_chunk, similarity} -> similarity >= threshold end)
    |> Enum.sort_by(fn {_chunk, similarity} -> similarity end, :desc)
    |> Enum.take(top_k)
    |> Enum.map(fn {chunk, similarity} ->
      # Get document info
      {:ok, doc} = DocumentStore.get_document(chunk.doc_id)
      %{
        chunk: chunk,
        document: doc,
        score: Float.round(similarity, 4),
        type: :semantic
      }
    end)
  end

  defp keyword_search(query, opts) do
    top_k = Keyword.get(opts, :top_k, 5)
    query_terms = String.downcase(query) |> String.split(~r/\s+/)

    DocumentStore.all_chunks()
    |> Enum.map(fn chunk ->
      content_lower = String.downcase(chunk.content)
      score = Enum.count(query_terms, fn term ->
        String.contains?(content_lower, term)
      end) / max(length(query_terms), 1)
      {chunk, score}
    end)
    |> Enum.filter(fn {_chunk, score} -> score > 0 end)
    |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)
    |> Enum.take(top_k)
    |> Enum.map(fn {chunk, score} ->
      {:ok, doc} = DocumentStore.get_document(chunk.doc_id)
      %{
        chunk: chunk,
        document: doc,
        score: Float.round(score, 4),
        type: :keyword
      }
    end)
  end

  defp cosine_similarity(vec1, vec2) when length(vec1) == length(vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    norm1 = :math.sqrt(Enum.reduce(vec1, 0.0, fn x, acc -> acc + x * x end))
    norm2 = :math.sqrt(Enum.reduce(vec2, 0.0, fn x, acc -> acc + x * x end))

    if norm1 > 0 and norm2 > 0 do
      dot_product / (norm1 * norm2)
    else
      0.0
    end
  end

  defp cosine_similarity(_, _), do: 0.0
end
