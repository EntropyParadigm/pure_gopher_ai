defmodule PureGopherAi.Rag.FileWatcher do
  @moduledoc """
  Watches the docs directory for new files and auto-ingests them.
  Uses polling since file_system requires native dependencies.
  """

  use GenServer
  require Logger

  alias PureGopherAi.Rag.DocumentStore
  alias PureGopherAi.Rag.Embeddings

  @poll_interval 30_000  # Check every 30 seconds

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Forces an immediate scan of the docs directory.
  """
  def scan_now do
    GenServer.cast(__MODULE__, :scan)
  end

  @doc """
  Returns the watched directory path.
  """
  def watched_dir do
    get_docs_dir()
  end

  @doc """
  Returns watcher status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    docs_dir = get_docs_dir()

    # Ensure directory exists
    File.mkdir_p!(docs_dir)

    # Get initial file list
    initial_files = scan_files(docs_dir)

    # Schedule first poll
    schedule_poll()

    Logger.info("RAG FileWatcher: Watching #{docs_dir}")
    {:ok, %{
      docs_dir: docs_dir,
      known_files: initial_files,
      last_scan: DateTime.utc_now(),
      files_ingested: 0
    }}
  end

  @impl true
  def handle_cast(:scan, state) do
    new_state = do_scan(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      watched_dir: state.docs_dir,
      known_files: MapSet.size(state.known_files),
      last_scan: state.last_scan,
      files_ingested: state.files_ingested
    }
    {:reply, status, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_scan(state)
    schedule_poll()
    {:noreply, new_state}
  end

  # Private functions

  defp get_docs_dir do
    Application.get_env(:pure_gopher_ai, :rag_docs_dir, "~/.gopher/docs")
    |> Path.expand()
  end

  defp schedule_poll do
    interval = Application.get_env(:pure_gopher_ai, :rag_poll_interval, @poll_interval)
    Process.send_after(self(), :poll, interval)
  end

  defp scan_files(dir) do
    if File.dir?(dir) do
      Path.wildcard(Path.join(dir, "**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&supported_file?/1)
      |> Enum.map(fn path -> {path, file_mtime(path)} end)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp supported_file?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in [".txt", ".md", ".markdown", ".pdf", ".text"]
  end

  defp do_scan(state) do
    current_files = scan_files(state.docs_dir)

    # Find new files (in current but not in known)
    new_files =
      MapSet.difference(current_files, state.known_files)
      |> MapSet.to_list()
      |> Enum.map(fn {path, _mtime} -> path end)

    # Find removed files (in known but not in current)
    removed_files =
      MapSet.difference(state.known_files, current_files)
      |> MapSet.to_list()
      |> Enum.map(fn {path, _mtime} -> path end)

    # Ingest new files
    ingested_count =
      Enum.reduce(new_files, 0, fn path, count ->
        case DocumentStore.ingest(path) do
          {:ok, doc} ->
            Logger.info("RAG FileWatcher: Auto-ingested #{doc.filename}")
            # Trigger embedding for new document
            Embeddings.embed_all_chunks()
            count + 1

          {:error, :already_ingested} ->
            count

          {:error, reason} ->
            Logger.warning("RAG FileWatcher: Failed to ingest #{path}: #{inspect(reason)}")
            count
        end
      end)

    # Log removed files (documents stay in store, just log for awareness)
    Enum.each(removed_files, fn path ->
      Logger.info("RAG FileWatcher: File removed from watch dir: #{Path.basename(path)}")
    end)

    %{state |
      known_files: current_files,
      last_scan: DateTime.utc_now(),
      files_ingested: state.files_ingested + ingested_count
    }
  end
end
