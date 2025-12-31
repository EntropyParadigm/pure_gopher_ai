defmodule PureGopherAi.Rag do
  @moduledoc """
  RAG (Retrieval Augmented Generation) for PureGopherAI.

  Enables AI queries to be augmented with relevant context from ingested documents.
  Documents are chunked, embedded, and searched semantically to provide relevant
  context for AI responses.

  ## Usage

  1. Drop documents into ~/.gopher/docs/ (auto-ingested)
  2. Or use admin commands: /admin/<token>/ingest <path>
  3. Query with: /docs/ask <question>

  ## Supported Formats

  - Plain text (.txt, .text)
  - Markdown (.md, .markdown)
  - PDF (.pdf) - requires pdftotext for best results
  """

  require Logger

  alias PureGopherAi.Rag.DocumentStore
  alias PureGopherAi.Rag.Embeddings
  alias PureGopherAi.AiEngine

  @doc """
  Queries documents with AI-augmented response.
  Retrieves relevant context and generates an AI response.
  """
  def query(question, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 3)

    # Search for relevant chunks
    case Embeddings.search(question, top_k: top_k) do
      {:ok, results} when results != [] ->
        # Build context from results
        context = build_context(results)

        # Create augmented prompt
        augmented_prompt = build_augmented_prompt(question, context)

        # Generate AI response (uses default model)
        AiEngine.generate(augmented_prompt)

      {:ok, []} ->
        # No relevant documents found, answer without context
        {:ok, "No relevant documents found for your query. Please try a different question or add more documents to the knowledge base."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Queries documents with streaming AI response.
  """
  def query_stream(question, callback, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 3)

    case Embeddings.search(question, top_k: top_k) do
      {:ok, results} when results != [] ->
        context = build_context(results)
        augmented_prompt = build_augmented_prompt(question, context)

        # Generate streaming response (uses default model)
        AiEngine.generate_stream(augmented_prompt, [], callback)

      {:ok, []} ->
        callback.("No relevant documents found for your query.")
        {:ok, "No relevant documents found for your query."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Searches documents and returns matching chunks with scores.
  """
  def search(query, opts \\ []) do
    Embeddings.search(query, opts)
  end

  @doc """
  Lists all ingested documents.
  """
  def list_documents do
    DocumentStore.list_documents()
  end

  @doc """
  Gets document info by ID.
  """
  def get_document(doc_id) do
    DocumentStore.get_document(doc_id)
  end

  @doc """
  Ingests a document from a file path.
  """
  def ingest(path) do
    case DocumentStore.ingest(path) do
      {:ok, doc} ->
        # Trigger embedding
        Embeddings.embed_all_chunks()
        {:ok, doc}

      error ->
        error
    end
  end

  @doc """
  Ingests a document from a URL.
  """
  def ingest_url(url) do
    case DocumentStore.ingest_url(url) do
      {:ok, doc} ->
        Embeddings.embed_all_chunks()
        {:ok, doc}

      error ->
        error
    end
  end

  @doc """
  Removes a document.
  """
  def remove(doc_id) do
    DocumentStore.remove(doc_id)
  end

  @doc """
  Returns RAG system statistics.
  """
  def stats do
    doc_stats = DocumentStore.stats()
    embedding_info = Embeddings.model_info()

    Map.merge(doc_stats, %{
      embedding_model: embedding_info.model,
      embeddings_enabled: embedding_info.enabled,
      embeddings_loaded: embedding_info.loaded
    })
  end

  @doc """
  Checks if RAG is enabled.
  """
  def enabled? do
    Application.get_env(:pure_gopher_ai, :rag_enabled, true)
  end

  @doc """
  Gets the docs directory path.
  """
  def docs_dir do
    Application.get_env(:pure_gopher_ai, :rag_docs_dir, "~/.gopher/docs")
    |> Path.expand()
  end

  # Private functions

  defp build_context(results) do
    results
    |> Enum.map(fn %{chunk: chunk, document: doc, score: score} ->
      """
      [Source: #{doc.filename} (relevance: #{score})]
      #{chunk.content}
      """
    end)
    |> Enum.join("\n---\n")
  end

  defp build_augmented_prompt(question, context) do
    """
    Use the following context to answer the question. If the context doesn't contain relevant information, say so.

    Context:
    #{context}

    Question: #{question}

    Answer based on the context above:
    """
  end
end
