defmodule PureGopherAi.LinkDirectory do
  @moduledoc """
  Curated directory of Gopher and Gemini links.

  Features:
  - Browse by category
  - Submit new links
  - Admin approval workflow
  - Persistent storage via DETS
  - Link health checking
  - AI-generated descriptions
  """

  use GenServer
  require Logger

  alias PureGopherAi.AiEngine

  @table_name :link_directory
  @pending_table :link_directory_pending
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")

  @default_categories %{
    "gopher" => %{
      name: "Gopher Servers",
      description: "Active Gopher servers and phlogs",
      icon: "1"
    },
    "gemini" => %{
      name: "Gemini Capsules",
      description: "Gemini protocol sites and blogs",
      icon: "1"
    },
    "tech" => %{
      name: "Technology",
      description: "Tech news, tutorials, and resources",
      icon: "1"
    },
    "retro" => %{
      name: "Retro Computing",
      description: "Vintage computers, retrocomputing, and nostalgia",
      icon: "1"
    },
    "programming" => %{
      name: "Programming",
      description: "Coding resources, languages, and tools",
      icon: "1"
    },
    "art" => %{
      name: "ASCII Art & Culture",
      description: "ASCII art, demoscene, and digital culture",
      icon: "1"
    },
    "writing" => %{
      name: "Writing & Literature",
      description: "Fiction, poetry, essays, and zines",
      icon: "1"
    },
    "games" => %{
      name: "Games & Fun",
      description: "Games, puzzles, and entertainment",
      icon: "1"
    },
    "misc" => %{
      name: "Miscellaneous",
      description: "Everything else",
      icon: "1"
    }
  }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all categories with link counts.
  """
  def list_categories do
    GenServer.call(__MODULE__, :list_categories)
  end

  @doc """
  Get all links in a category.
  """
  def get_category(category_id) do
    GenServer.call(__MODULE__, {:get_category, category_id})
  end

  @doc """
  Get a single link by ID.
  """
  def get_link(link_id) do
    GenServer.call(__MODULE__, {:get_link, link_id})
  end

  @doc """
  Submit a new link (pending approval).
  """
  def submit_link(url, title, category, description \\ nil, submitter_ip \\ nil) do
    GenServer.call(__MODULE__, {:submit_link, url, title, category, description, submitter_ip})
  end

  @doc """
  List pending links (admin).
  """
  def list_pending do
    GenServer.call(__MODULE__, :list_pending)
  end

  @doc """
  Approve a pending link (admin).
  """
  def approve_link(link_id) do
    GenServer.call(__MODULE__, {:approve_link, link_id})
  end

  @doc """
  Reject a pending link (admin).
  """
  def reject_link(link_id) do
    GenServer.call(__MODULE__, {:reject_link, link_id})
  end

  @doc """
  Search links by keyword.
  """
  def search(query) do
    GenServer.call(__MODULE__, {:search, query})
  end

  @doc """
  Get link statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Generate AI description for a link.
  """
  def generate_description(url, title) do
    GenServer.call(__MODULE__, {:generate_description, url, title}, 60_000)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "links.dets") |> String.to_charlist()
    pending_file = Path.join(data_dir, "links_pending.dets") |> String.to_charlist()

    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)
    {:ok, _} = :dets.open_file(@pending_table, file: pending_file, type: :set)

    # Add some seed links if empty
    if :dets.info(@table_name, :size) == 0 do
      seed_links()
    end

    {:ok, %{categories: @default_categories}}
  end

  @impl true
  def handle_call(:list_categories, _from, state) do
    # Count links per category
    all_links = :dets.foldl(fn {_id, link}, acc -> [link | acc] end, [], @table_name)

    counts = Enum.reduce(all_links, %{}, fn link, acc ->
      Map.update(acc, link.category, 1, &(&1 + 1))
    end)

    categories = state.categories
      |> Enum.map(fn {id, cat} ->
        count = Map.get(counts, id, 0)
        %{id: id, name: cat.name, description: cat.description, count: count, icon: cat.icon}
      end)
      |> Enum.filter(fn cat -> cat.count > 0 or cat.id in ["gopher", "gemini", "misc"] end)
      |> Enum.sort_by(& &1.name)

    {:reply, {:ok, categories}, state}
  end

  @impl true
  def handle_call({:get_category, category_id}, _from, state) do
    case Map.get(state.categories, category_id) do
      nil ->
        {:reply, {:error, :category_not_found}, state}

      cat_info ->
        links = :dets.foldl(fn {_id, link}, acc ->
          if link.category == category_id, do: [link | acc], else: acc
        end, [], @table_name)
        |> Enum.sort_by(& &1.title)

        {:reply, {:ok, %{info: cat_info, links: links}}, state}
    end
  end

  @impl true
  def handle_call({:get_link, link_id}, _from, state) do
    case :dets.lookup(@table_name, link_id) do
      [{^link_id, link}] -> {:reply, {:ok, link}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:submit_link, url, title, category, description, submitter_ip}, _from, state) do
    if Map.has_key?(state.categories, category) do
      link_id = generate_id()
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      pending_link = %{
        id: link_id,
        url: String.trim(url),
        title: String.trim(title),
        category: category,
        description: description,
        submitter_ip: format_ip(submitter_ip),
        submitted_at: now,
        status: :pending
      }

      :dets.insert(@pending_table, {link_id, pending_link})
      :dets.sync(@pending_table)

      {:reply, {:ok, link_id}, state}
    else
      {:reply, {:error, :invalid_category}, state}
    end
  end

  @impl true
  def handle_call(:list_pending, _from, state) do
    pending = :dets.foldl(fn {_id, link}, acc -> [link | acc] end, [], @pending_table)
      |> Enum.sort_by(& &1.submitted_at)

    {:reply, {:ok, pending}, state}
  end

  @impl true
  def handle_call({:approve_link, link_id}, _from, state) do
    case :dets.lookup(@pending_table, link_id) do
      [{^link_id, pending_link}] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        approved_link = %{
          id: link_id,
          url: pending_link.url,
          title: pending_link.title,
          category: pending_link.category,
          description: pending_link.description,
          added_at: now,
          status: :approved
        }

        :dets.insert(@table_name, {link_id, approved_link})
        :dets.delete(@pending_table, link_id)
        :dets.sync(@table_name)
        :dets.sync(@pending_table)

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:reject_link, link_id}, _from, state) do
    case :dets.lookup(@pending_table, link_id) do
      [{^link_id, _}] ->
        :dets.delete(@pending_table, link_id)
        :dets.sync(@pending_table)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:search, query}, _from, state) do
    query_lower = String.downcase(query)

    results = :dets.foldl(fn {_id, link}, acc ->
      title_match = String.contains?(String.downcase(link.title), query_lower)
      url_match = String.contains?(String.downcase(link.url), query_lower)
      desc_match = link.description && String.contains?(String.downcase(link.description), query_lower)

      if title_match or url_match or desc_match do
        [link | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.sort_by(& &1.title)

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total = :dets.info(@table_name, :size)
    pending = :dets.info(@pending_table, :size)

    by_category = :dets.foldl(fn {_id, link}, acc ->
      Map.update(acc, link.category, 1, &(&1 + 1))
    end, %{}, @table_name)

    {:reply, {:ok, %{total: total, pending: pending, by_category: by_category}}, state}
  end

  @impl true
  def handle_call({:generate_description, url, title}, _from, state) do
    prompt = """
    Generate a brief, one-sentence description for this link:
    Title: #{title}
    URL: #{url}

    Write a concise description (under 100 characters) that explains what this site is about.
    Focus on the content type and main purpose.
    """

    case AiEngine.generate(prompt, max_new_tokens: 50) do
      {:ok, description} ->
        clean_desc = description
          |> String.trim()
          |> String.replace(~r/^Description:\s*/i, "")
          |> String.slice(0, 150)

        {:reply, {:ok, clean_desc}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :dets.close(@pending_table)
    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(nil), do: "unknown"
  defp format_ip(ip), do: inspect(ip)

  defp seed_links do
    # Seed with some well-known Gopher servers
    seed_data = [
      # Gopher servers
      {"gopher://gopher.floodgap.com/", "Floodgap Systems", "gopher",
       "One of the oldest and most active Gopher servers"},
      {"gopher://gopher.quux.org/", "Quux.org", "gopher",
       "Community Gopher server with diverse content"},
      {"gopher://sdf.org/", "SDF Public Access UNIX", "gopher",
       "Free shell account provider with Gopher hosting"},
      {"gopher://zaibatsu.circumlunar.space/", "Zaibatsu", "gopher",
       "Tildeverse Gopher community"},
      {"gopher://bitreich.org/", "Bitreich", "gopher",
       "Minimalist computing collective"},

      # Gemini capsules
      {"gemini://gemini.circumlunar.space/", "Project Gemini", "gemini",
       "Official Gemini protocol documentation"},
      {"gemini://kennedy.gemi.dev/", "Kennedy", "gemini",
       "Gemini client and tools developer"},
      {"gemini://rawtext.club/", "RawText Club", "gemini",
       "Minimalist text-focused capsule"},

      # Tech resources
      {"gopher://gopher.club/", "Gopher Club", "tech",
       "Meta-resources for Gopher enthusiasts"},
      {"gemini://gemini.conman.org/", "Gemini at conman.org", "tech",
       "Technical Gemini resources and experiments"},

      # Retro
      {"gopher://gopher.vk1oo.net/", "VK1OO Gopher", "retro",
       "Vintage computing and amateur radio"},

      # Programming
      {"gopher://codevoid.de/", "Codevoid", "programming",
       "Programming projects and tutorials"}
    ]

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.each(seed_data, fn {url, title, category, description} ->
      id = generate_id()
      link = %{
        id: id,
        url: url,
        title: title,
        category: category,
        description: description,
        added_at: now,
        status: :approved
      }
      :dets.insert(@table_name, {id, link})
    end)

    :dets.sync(@table_name)
    Logger.info("Link Directory: Seeded #{length(seed_data)} initial links")
  end
end
