defmodule PureGopherAi.Slides do
  @moduledoc """
  Terminal-based presentation system with ASCII/ANSI art visuals.

  Features:
  - Create, edit, view slide presentations
  - Rich visuals: ASCII art, ANSI colors, borders
  - Multiple templates: title, content, two-column, code, image, quote
  - Markdown export for portability
  - Speaker notes support
  - Slide transitions
  """

  use GenServer
  require Logger

  @table_name :slides
  @data_dir "~/.gopher/data"
  @max_slides_per_deck 50
  @max_title_length 100
  @max_content_length 5000

  # Slide templates
  @templates [:title, :content, :two_column, :code, :image, :quote, :list, :comparison]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new slide deck.
  """
  def create_deck(title, author, opts \\ []) do
    GenServer.call(__MODULE__, {:create_deck, title, author, opts})
  end

  @doc """
  Gets a slide deck by ID.
  """
  def get_deck(deck_id) do
    GenServer.call(__MODULE__, {:get_deck, deck_id})
  end

  @doc """
  Lists all slide decks.
  """
  def list_decks(opts \\ []) do
    GenServer.call(__MODULE__, {:list_decks, opts})
  end

  @doc """
  Lists decks by author.
  """
  def list_by_author(author) do
    GenServer.call(__MODULE__, {:list_by_author, author})
  end

  @doc """
  Adds a slide to a deck.
  """
  def add_slide(deck_id, slide_type, content, opts \\ []) do
    GenServer.call(__MODULE__, {:add_slide, deck_id, slide_type, content, opts})
  end

  @doc """
  Updates a slide in a deck.
  """
  def update_slide(deck_id, slide_index, content, opts \\ []) do
    GenServer.call(__MODULE__, {:update_slide, deck_id, slide_index, content, opts})
  end

  @doc """
  Removes a slide from a deck.
  """
  def remove_slide(deck_id, slide_index) do
    GenServer.call(__MODULE__, {:remove_slide, deck_id, slide_index})
  end

  @doc """
  Reorders slides in a deck.
  """
  def reorder_slides(deck_id, new_order) do
    GenServer.call(__MODULE__, {:reorder_slides, deck_id, new_order})
  end

  @doc """
  Deletes a slide deck.
  """
  def delete_deck(deck_id) do
    GenServer.call(__MODULE__, {:delete_deck, deck_id})
  end

  @doc """
  Exports a deck to markdown format.
  """
  def export_markdown(deck_id) do
    GenServer.call(__MODULE__, {:export_markdown, deck_id})
  end

  @doc """
  Exports a deck to plain text format.
  """
  def export_text(deck_id) do
    GenServer.call(__MODULE__, {:export_text, deck_id})
  end

  @doc """
  Gets available templates.
  """
  def templates, do: @templates

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)
    dets_file = Path.join(data_dir, "slides.dets") |> String.to_charlist()

    case :dets.open_file(@table_name, file: dets_file, type: :set) do
      {:ok, table} ->
        Logger.info("[Slides] Started, loaded from #{dets_file}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("[Slides] Failed to open DETS: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:create_deck, title, author, opts}, _from, state) do
    title = title |> String.trim() |> String.slice(0, @max_title_length)
    description = Keyword.get(opts, :description, "")
    theme = Keyword.get(opts, :theme, :default)
    color_enabled = Keyword.get(opts, :color, false)

    deck_id = generate_id()
    now = DateTime.utc_now()

    deck = %{
      id: deck_id,
      title: title,
      author: author,
      description: description,
      theme: theme,
      color_enabled: color_enabled,
      slides: [],
      created_at: now,
      updated_at: now,
      view_count: 0,
      public: Keyword.get(opts, :public, true)
    }

    :dets.insert(@table_name, {deck_id, deck})
    :dets.sync(@table_name)

    {:reply, {:ok, deck}, state}
  end

  @impl true
  def handle_call({:get_deck, deck_id}, _from, state) do
    result = case :dets.lookup(@table_name, deck_id) do
      [{^deck_id, deck}] ->
        # Increment view count
        updated = %{deck | view_count: deck.view_count + 1}
        :dets.insert(@table_name, {deck_id, updated})
        {:ok, updated}
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_decks, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    public_only = Keyword.get(opts, :public_only, true)

    decks = :dets.foldl(fn {_id, deck}, acc ->
      if !public_only or deck.public do
        [deck | acc]
      else
        acc
      end
    end, [], @table_name)

    sorted = decks
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.take(limit)

    {:reply, sorted, state}
  end

  @impl true
  def handle_call({:list_by_author, author}, _from, state) do
    decks = :dets.foldl(fn {_id, deck}, acc ->
      if deck.author == author do
        [deck | acc]
      else
        acc
      end
    end, [], @table_name)

    sorted = Enum.sort_by(decks, & &1.updated_at, {:desc, DateTime})
    {:reply, sorted, state}
  end

  @impl true
  def handle_call({:add_slide, deck_id, slide_type, content, opts}, _from, state) do
    result = case :dets.lookup(@table_name, deck_id) do
      [{^deck_id, deck}] ->
        if length(deck.slides) >= @max_slides_per_deck do
          {:error, :max_slides_reached}
        else
          slide = create_slide(slide_type, content, opts)
          updated_slides = deck.slides ++ [slide]
          updated_deck = %{deck | slides: updated_slides, updated_at: DateTime.utc_now()}
          :dets.insert(@table_name, {deck_id, updated_deck})
          :dets.sync(@table_name)
          {:ok, updated_deck}
        end
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_slide, deck_id, slide_index, content, opts}, _from, state) do
    result = case :dets.lookup(@table_name, deck_id) do
      [{^deck_id, deck}] ->
        if slide_index < 0 or slide_index >= length(deck.slides) do
          {:error, :invalid_index}
        else
          slide = Enum.at(deck.slides, slide_index)
          updated_slide = update_slide_content(slide, content, opts)
          updated_slides = List.replace_at(deck.slides, slide_index, updated_slide)
          updated_deck = %{deck | slides: updated_slides, updated_at: DateTime.utc_now()}
          :dets.insert(@table_name, {deck_id, updated_deck})
          :dets.sync(@table_name)
          {:ok, updated_deck}
        end
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:remove_slide, deck_id, slide_index}, _from, state) do
    result = case :dets.lookup(@table_name, deck_id) do
      [{^deck_id, deck}] ->
        if slide_index < 0 or slide_index >= length(deck.slides) do
          {:error, :invalid_index}
        else
          updated_slides = List.delete_at(deck.slides, slide_index)
          updated_deck = %{deck | slides: updated_slides, updated_at: DateTime.utc_now()}
          :dets.insert(@table_name, {deck_id, updated_deck})
          :dets.sync(@table_name)
          {:ok, updated_deck}
        end
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:reorder_slides, deck_id, new_order}, _from, state) do
    result = case :dets.lookup(@table_name, deck_id) do
      [{^deck_id, deck}] ->
        slide_count = length(deck.slides)
        if length(new_order) != slide_count or
           Enum.sort(new_order) != Enum.to_list(0..(slide_count - 1)) do
          {:error, :invalid_order}
        else
          reordered = Enum.map(new_order, &Enum.at(deck.slides, &1))
          updated_deck = %{deck | slides: reordered, updated_at: DateTime.utc_now()}
          :dets.insert(@table_name, {deck_id, updated_deck})
          :dets.sync(@table_name)
          {:ok, updated_deck}
        end
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_deck, deck_id}, _from, state) do
    result = case :dets.lookup(@table_name, deck_id) do
      [{^deck_id, _deck}] ->
        :dets.delete(@table_name, deck_id)
        :dets.sync(@table_name)
        :ok
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:export_markdown, deck_id}, _from, state) do
    result = case :dets.lookup(@table_name, deck_id) do
      [{^deck_id, deck}] ->
        markdown = generate_markdown(deck)
        {:ok, markdown}
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:export_text, deck_id}, _from, state) do
    result = case :dets.lookup(@table_name, deck_id) do
      [{^deck_id, deck}] ->
        text = generate_plain_text(deck)
        {:ok, text}
      [] ->
        {:error, :not_found}
    end
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp create_slide(type, content, opts) when type in @templates do
    %{
      type: type,
      title: Keyword.get(opts, :title, ""),
      content: content |> String.trim() |> String.slice(0, @max_content_length),
      notes: Keyword.get(opts, :notes, ""),
      transition: Keyword.get(opts, :transition, :fade),
      duration: Keyword.get(opts, :duration, nil),
      layout: Keyword.get(opts, :layout, %{}),
      created_at: DateTime.utc_now()
    }
  end

  defp create_slide(_type, content, opts) do
    create_slide(:content, content, opts)
  end

  defp update_slide_content(slide, content, opts) do
    %{slide |
      content: content |> String.trim() |> String.slice(0, @max_content_length),
      title: Keyword.get(opts, :title, slide.title),
      notes: Keyword.get(opts, :notes, slide.notes),
      transition: Keyword.get(opts, :transition, slide.transition),
      duration: Keyword.get(opts, :duration, slide.duration)
    }
  end

  defp generate_markdown(deck) do
    header = """
    ---
    title: #{deck.title}
    author: #{deck.author}
    description: #{deck.description}
    theme: #{deck.theme}
    created: #{DateTime.to_iso8601(deck.created_at)}
    ---

    """

    slides_md = deck.slides
    |> Enum.with_index(1)
    |> Enum.map(fn {slide, index} ->
      slide_to_markdown(slide, index)
    end)
    |> Enum.join("\n---\n\n")

    header <> slides_md
  end

  defp slide_to_markdown(slide, index) do
    title_line = if slide.title != "", do: "# #{slide.title}\n\n", else: ""
    notes_section = if slide.notes != "", do: "\n\n<!-- Speaker notes:\n#{slide.notes}\n-->", else: ""

    content = case slide.type do
      :title ->
        "# #{slide.content}"

      :code ->
        "```\n#{slide.content}\n```"

      :quote ->
        "> #{slide.content}"

      :list ->
        slide.content
        |> String.split("\n")
        |> Enum.map(&"- #{&1}")
        |> Enum.join("\n")

      :two_column ->
        # Assume content is separated by |||
        case String.split(slide.content, "|||") do
          [left, right] ->
            """
            | Left | Right |
            |------|-------|
            | #{String.trim(left)} | #{String.trim(right)} |
            """
          _ ->
            slide.content
        end

      :image ->
        "![#{slide.title}](#{slide.content})"

      :comparison ->
        slide.content

      _ ->
        slide.content
    end

    "<!-- Slide #{index} -->\n#{title_line}#{content}#{notes_section}\n"
  end

  defp generate_plain_text(deck) do
    header = """
    ================================================================================
    #{String.upcase(deck.title)}
    by #{deck.author}
    ================================================================================

    #{deck.description}

    """

    slides_text = deck.slides
    |> Enum.with_index(1)
    |> Enum.map(fn {slide, index} ->
      slide_to_plain_text(slide, index, length(deck.slides))
    end)
    |> Enum.join("\n")

    header <> slides_text
  end

  defp slide_to_plain_text(slide, index, total) do
    divider = String.duplicate("-", 80)
    title_line = if slide.title != "", do: "\n  #{String.upcase(slide.title)}\n", else: ""

    content = slide.content
    |> String.split("\n")
    |> Enum.map(&"  #{&1}")
    |> Enum.join("\n")

    notes = if slide.notes != "" do
      "\n\n  [Speaker Notes]\n  #{slide.notes}"
    else
      ""
    end

    """
    #{divider}
    SLIDE #{index}/#{total}#{title_line}
    #{content}#{notes}

    """
  end
end
