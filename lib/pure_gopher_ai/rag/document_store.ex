defmodule PureGopherAi.Rag.DocumentStore do
  @moduledoc """
  Document store for RAG (Retrieval Augmented Generation).
  Manages document ingestion, chunking, and metadata storage.
  """

  use GenServer
  require Logger

  @table_name :rag_documents
  @chunks_table :rag_chunks
  @default_chunk_size 512
  @default_chunk_overlap 50

  # Document structure:
  # %{
  #   id: string,
  #   path: string,
  #   filename: string,
  #   type: :txt | :md | :pdf,
  #   size: integer,
  #   chunk_count: integer,
  #   ingested_at: DateTime,
  #   metadata: map
  # }

  # Chunk structure:
  # %{
  #   id: string,
  #   doc_id: string,
  #   index: integer,
  #   content: string,
  #   embedding: list | nil
  # }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ingests a document from a file path.
  """
  def ingest(path) do
    GenServer.call(__MODULE__, {:ingest, path}, 60_000)
  end

  @doc """
  Ingests a document from a URL.
  """
  def ingest_url(url) do
    GenServer.call(__MODULE__, {:ingest_url, url}, 60_000)
  end

  @doc """
  Removes a document and its chunks.
  """
  def remove(doc_id) do
    GenServer.call(__MODULE__, {:remove, doc_id})
  end

  @doc """
  Lists all ingested documents.
  """
  def list_documents do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_id, doc} -> doc end)
    |> Enum.sort_by(& &1.ingested_at, {:desc, DateTime})
  end

  @doc """
  Gets a document by ID.
  """
  def get_document(doc_id) do
    case :ets.lookup(@table_name, doc_id) do
      [{^doc_id, doc}] -> {:ok, doc}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets all chunks for a document.
  """
  def get_chunks(doc_id) do
    :ets.match_object(@chunks_table, {:_, %{doc_id: doc_id}})
    |> Enum.map(fn {_id, chunk} -> chunk end)
    |> Enum.sort_by(& &1.index)
  end

  @doc """
  Gets a specific chunk by ID.
  """
  def get_chunk(chunk_id) do
    case :ets.lookup(@chunks_table, chunk_id) do
      [{^chunk_id, chunk}] -> {:ok, chunk}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns all chunks (for embedding/search).
  """
  def all_chunks do
    :ets.tab2list(@chunks_table)
    |> Enum.map(fn {_id, chunk} -> chunk end)
  end

  @doc """
  Updates a chunk's embedding.
  """
  def update_embedding(chunk_id, embedding) do
    GenServer.call(__MODULE__, {:update_embedding, chunk_id, embedding})
  end

  @doc """
  Returns store statistics.
  """
  def stats do
    doc_count = :ets.info(@table_name, :size) || 0
    chunk_count = :ets.info(@chunks_table, :size) || 0

    embedded_count =
      all_chunks()
      |> Enum.count(fn chunk -> chunk.embedding != nil end)

    %{
      documents: doc_count,
      chunks: chunk_count,
      embedded_chunks: embedded_count,
      embedding_coverage: if(chunk_count > 0, do: Float.round(embedded_count / chunk_count * 100, 1), else: 0.0)
    }
  end

  @doc """
  Clears all documents and chunks.
  """
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set])
    :ets.new(@chunks_table, [:named_table, :public, :set])

    # Schedule initial scan of docs directory
    send(self(), :scan_docs_dir)

    Logger.info("RAG DocumentStore started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ingest, path}, _from, state) do
    result = do_ingest(path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:ingest_url, url}, _from, state) do
    result = do_ingest_url(url)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:remove, doc_id}, _from, state) do
    # Remove all chunks for this document
    chunks = get_chunks(doc_id)
    Enum.each(chunks, fn chunk ->
      :ets.delete(@chunks_table, chunk.id)
    end)

    # Remove the document
    :ets.delete(@table_name, doc_id)

    Logger.info("RAG: Removed document #{doc_id} with #{length(chunks)} chunks")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_embedding, chunk_id, embedding}, _from, state) do
    case :ets.lookup(@chunks_table, chunk_id) do
      [{^chunk_id, chunk}] ->
        updated = %{chunk | embedding: embedding}
        :ets.insert(@chunks_table, {chunk_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table_name)
    :ets.delete_all_objects(@chunks_table)
    Logger.info("RAG: Cleared all documents and chunks")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:scan_docs_dir, state) do
    docs_dir = get_docs_dir()

    if File.dir?(docs_dir) do
      scan_and_ingest_directory(docs_dir)
    else
      Logger.info("RAG: Docs directory #{docs_dir} does not exist, creating...")
      File.mkdir_p!(docs_dir)
    end

    {:noreply, state}
  end

  # Private functions

  defp get_docs_dir do
    Application.get_env(:pure_gopher_ai, :rag_docs_dir, "~/.gopher/docs")
    |> Path.expand()
  end

  # Security: Validate path is within allowed directories to prevent path traversal
  defp path_allowed?(expanded_path) do
    docs_dir = get_docs_dir()
    temp_dir = System.tmp_dir!() |> Path.expand()

    # Path must start with either the docs directory or temp directory
    String.starts_with?(expanded_path, docs_dir <> "/") or
      expanded_path == docs_dir or
      String.starts_with?(expanded_path, temp_dir <> "/") or
      expanded_path == temp_dir
  end

  defp scan_and_ingest_directory(dir) do
    Logger.info("RAG: Scanning #{dir} for documents...")

    files =
      Path.wildcard(Path.join(dir, "**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&supported_file?/1)

    Logger.info("RAG: Found #{length(files)} supported files")

    Enum.each(files, fn path ->
      case do_ingest(path) do
        {:ok, doc} ->
          Logger.info("RAG: Ingested #{doc.filename} (#{doc.chunk_count} chunks)")

        {:error, reason} ->
          Logger.warning("RAG: Failed to ingest #{path}: #{inspect(reason)}")
      end
    end)
  end

  defp supported_file?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in [".txt", ".md", ".markdown", ".pdf", ".text"]
  end

  defp do_ingest(path) do
    expanded = Path.expand(path)

    cond do
      # Security: Validate path is within allowed directories
      not path_allowed?(expanded) ->
        Logger.warning("RAG: Path traversal attempt blocked: #{path}")
        {:error, :path_not_allowed}

      not File.exists?(expanded) ->
        {:error, :file_not_found}

      true ->
        case extract_text(expanded) do
          {:ok, text} ->
            doc_id = generate_doc_id(expanded)

            # Check if already ingested
            case :ets.lookup(@table_name, doc_id) do
              [{^doc_id, _existing}] ->
                {:error, :already_ingested}

              [] ->
                # Create chunks
                chunks = chunk_text(text, doc_id)

                # Store chunks
                Enum.each(chunks, fn chunk ->
                  :ets.insert(@chunks_table, {chunk.id, chunk})
                end)

                # Store document metadata
                doc = %{
                  id: doc_id,
                  path: expanded,
                  filename: Path.basename(expanded),
                  type: detect_type(expanded),
                  size: File.stat!(expanded).size,
                  chunk_count: length(chunks),
                  ingested_at: DateTime.utc_now(),
                  metadata: %{}
                }

                :ets.insert(@table_name, {doc_id, doc})

                {:ok, doc}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp do_ingest_url(url) do
    # Download to temp file and ingest
    :inets.start()
    :ssl.start()

    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, []}, [{:timeout, 60_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        # Determine filename from URL
        filename = url |> URI.parse() |> Map.get(:path, "/file") |> Path.basename()
        filename = if filename == "", do: "downloaded_file.txt", else: filename

        # Write to temp file
        temp_path = Path.join(System.tmp_dir!(), "rag_#{:rand.uniform(999999)}_#{filename}")
        File.write!(temp_path, body)

        # Ingest
        result = do_ingest(temp_path)

        # Clean up temp file
        File.rm(temp_path)

        result

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_text(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ext when ext in [".txt", ".text"] ->
        File.read(path)

      ext when ext in [".md", ".markdown"] ->
        # For markdown, we keep it as-is (could strip formatting later)
        File.read(path)

      ".pdf" ->
        extract_pdf_text(path)

      _ ->
        {:error, :unsupported_format}
    end
  end

  defp extract_pdf_text(path) do
    # Try pdftotext if available
    case System.find_executable("pdftotext") do
      nil ->
        # Fallback: try to read as binary and extract printable text
        case File.read(path) do
          {:ok, binary} ->
            # Very basic text extraction from PDF
            text = extract_printable_text(binary)
            if String.length(text) > 100 do
              {:ok, text}
            else
              {:error, :pdf_extraction_failed}
            end

          error ->
            error
        end

      pdftotext ->
        # Use pdftotext for proper extraction
        temp_out = Path.join(System.tmp_dir!(), "rag_pdf_#{:rand.uniform(999999)}.txt")

        case System.cmd(pdftotext, ["-layout", path, temp_out], stderr_to_stdout: true) do
          {_, 0} ->
            result = File.read(temp_out)
            File.rm(temp_out)
            result

          {error, _} ->
            File.rm(temp_out)
            {:error, {:pdftotext_failed, error}}
        end
    end
  end

  defp extract_printable_text(binary) do
    # Extract sequences of printable ASCII characters
    binary
    |> :binary.bin_to_list()
    |> Enum.filter(fn byte -> byte >= 32 and byte < 127 end)
    |> List.to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp detect_type(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ext when ext in [".txt", ".text"] -> :txt
      ext when ext in [".md", ".markdown"] -> :md
      ".pdf" -> :pdf
      _ -> :unknown
    end
  end

  defp generate_doc_id(path) do
    :crypto.hash(:sha256, path)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp chunk_text(text, doc_id) do
    chunk_size = Application.get_env(:pure_gopher_ai, :rag_chunk_size, @default_chunk_size)
    overlap = Application.get_env(:pure_gopher_ai, :rag_chunk_overlap, @default_chunk_overlap)

    # Split into words
    words = String.split(text, ~r/\s+/)

    # Create overlapping chunks
    chunks = create_chunks(words, chunk_size, overlap)

    # Convert to chunk structs
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {content, index} ->
      chunk_id = "#{doc_id}_#{index}"
      %{
        id: chunk_id,
        doc_id: doc_id,
        index: index,
        content: content,
        embedding: nil
      }
    end)
  end

  defp create_chunks(words, chunk_size, _overlap) when length(words) <= chunk_size do
    [Enum.join(words, " ")]
  end

  defp create_chunks(words, chunk_size, overlap) do
    {chunk_words, remaining} = Enum.split(words, chunk_size)
    chunk = Enum.join(chunk_words, " ")

    # Include overlap from the end of current chunk
    overlap_words = Enum.take(chunk_words, -overlap)
    next_words = overlap_words ++ remaining

    [chunk | create_chunks(next_words, chunk_size, overlap)]
  end
end
