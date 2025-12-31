defmodule PureGopherAi.FeedAggregator do
  @moduledoc """
  RSS/Atom feed aggregator.

  Features:
  - Subscribe to RSS 2.0 and Atom feeds
  - Auto-refresh feeds on interval
  - Parse feed entries with title, link, date, content
  - AI-generated digest of all feeds
  - OPML export
  """

  use GenServer
  require Logger

  alias PureGopherAi.AiEngine

  @table_name :feed_aggregator
  @entries_table :feed_entries
  @refresh_interval_ms 1_800_000  # 30 minutes
  @max_entries_per_feed 50
  @fetch_timeout 15_000

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Lists all configured feeds.
  """
  def list_feeds do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {id, feed} -> {id, feed} end)
    |> Enum.sort_by(fn {_id, feed} -> feed.name end)
  end

  @doc """
  Gets a specific feed by ID.
  """
  def get_feed(feed_id) do
    case :ets.lookup(@table_name, feed_id) do
      [{^feed_id, feed}] -> {:ok, feed}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets entries for a specific feed.
  """
  def get_entries(feed_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    entries = :ets.match_object(@entries_table, {feed_id, :_, :_})
      |> Enum.map(fn {_feed_id, _entry_id, entry} -> entry end)
      |> Enum.sort_by(& &1.published_at, {:desc, DateTime})
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:ok, entries}
  end

  @doc """
  Gets a specific entry.
  """
  def get_entry(feed_id, entry_id) do
    case :ets.lookup(@entries_table, {feed_id, entry_id}) do
      [{{^feed_id, ^entry_id}, entry}] -> {:ok, entry}
      [{^feed_id, ^entry_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Gets all recent entries across all feeds.
  """
  def get_all_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    entries = :ets.tab2list(@entries_table)
      |> Enum.map(fn {_feed_id, _entry_id, entry} -> entry end)
      |> Enum.sort_by(& &1.published_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:ok, entries}
  end

  @doc """
  Adds a new feed subscription.
  """
  def add_feed(url, opts \\ []) do
    GenServer.call(__MODULE__, {:add_feed, url, opts}, 30_000)
  end

  @doc """
  Removes a feed subscription.
  """
  def remove_feed(feed_id) do
    GenServer.call(__MODULE__, {:remove_feed, feed_id})
  end

  @doc """
  Manually refreshes a specific feed.
  """
  def refresh_feed(feed_id) do
    GenServer.call(__MODULE__, {:refresh_feed, feed_id}, 30_000)
  end

  @doc """
  Refreshes all feeds.
  """
  def refresh_all do
    GenServer.cast(__MODULE__, :refresh_all)
  end

  @doc """
  Generates an AI digest of recent feed entries.
  """
  def generate_digest(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    {:ok, entries} = get_all_entries(limit: limit)

    if length(entries) == 0 do
      {:ok, "No recent feed entries to summarize."}
    else
      entries_text = entries
        |> Enum.take(15)
        |> Enum.map(fn entry ->
          date = if entry.published_at, do: Calendar.strftime(entry.published_at, "%Y-%m-%d"), else: "unknown"
          content = String.slice(entry.content || entry.summary || "", 0, 200)
          "- #{entry.title} (#{date}): #{content}"
        end)
        |> Enum.join("\n")

      prompt = """
      Summarize these recent RSS feed entries into a concise digest:

      #{entries_text}

      Provide a brief summary (3-5 bullet points) of the main topics and highlights.
      Focus on what's interesting or important.

      Digest:
      """

      AiEngine.generate(prompt, max_new_tokens: 300)
    end
  end

  @doc """
  Generates OPML export of all subscribed feeds.
  """
  def export_opml do
    feeds = list_feeds()

    outlines = feeds
      |> Enum.map(fn {_id, feed} ->
        ~s(<outline type="rss" text="#{escape_xml(feed.name)}" title="#{escape_xml(feed.name)}" xmlUrl="#{escape_xml(feed.url)}"/>)
      end)
      |> Enum.join("\n    ")

    opml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="2.0">
      <head>
        <title>PureGopherAI Feeds</title>
        <dateCreated>#{DateTime.utc_now() |> DateTime.to_iso8601()}</dateCreated>
      </head>
      <body>
        #{outlines}
      </body>
    </opml>
    """

    {:ok, opml}
  end

  @doc """
  Gets feed statistics.
  """
  def stats do
    feeds = list_feeds()
    entries_count = :ets.info(@entries_table, :size)

    %{
      feed_count: length(feeds),
      entry_count: entries_count,
      feeds: Enum.map(feeds, fn {id, feed} ->
        entry_count = :ets.match_object(@entries_table, {id, :_, :_}) |> length()
        %{id: id, name: feed.name, entries: entry_count, last_fetched: feed.last_fetched}
      end)
    }
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@entries_table, [:named_table, :bag, :public, read_concurrency: true])

    # Load configured feeds
    load_configured_feeds()

    # Schedule periodic refresh
    schedule_refresh()

    Logger.info("FeedAggregator: Initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_feed, url, opts}, _from, state) do
    result = do_add_feed(url, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:remove_feed, feed_id}, _from, state) do
    :ets.delete(@table_name, feed_id)
    :ets.match_delete(@entries_table, {feed_id, :_, :_})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:refresh_feed, feed_id}, _from, state) do
    result = case get_feed(feed_id) do
      {:ok, feed} -> fetch_and_parse_feed(feed_id, feed)
      error -> error
    end
    {:reply, result, state}
  end

  @impl true
  def handle_cast(:refresh_all, state) do
    do_refresh_all()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    do_refresh_all()
    schedule_refresh()
    {:noreply, state}
  end

  # Private Functions

  defp load_configured_feeds do
    feeds = Application.get_env(:pure_gopher_ai, :rss_feeds, [])

    Enum.each(feeds, fn {name, url} ->
      feed_id = generate_feed_id(url)
      feed = %{
        name: name,
        url: url,
        last_fetched: nil,
        error: nil
      }
      :ets.insert(@table_name, {feed_id, feed})
    end)

    # Fetch all feeds initially
    if length(feeds) > 0 do
      Task.start(fn -> do_refresh_all() end)
    end
  end

  defp do_add_feed(url, opts) do
    name = Keyword.get(opts, :name, nil)
    feed_id = generate_feed_id(url)

    # Check if already exists
    case :ets.lookup(@table_name, feed_id) do
      [{^feed_id, _}] ->
        {:error, :already_exists}
      [] ->
        # Fetch to validate and get title
        case fetch_feed(url) do
          {:ok, content} ->
            case parse_feed(content) do
              {:ok, parsed} ->
                feed = %{
                  name: name || parsed.title || url,
                  url: url,
                  last_fetched: DateTime.utc_now(),
                  error: nil
                }
                :ets.insert(@table_name, {feed_id, feed})
                store_entries(feed_id, parsed.entries)
                {:ok, feed_id}
              {:error, reason} ->
                {:error, {:parse_error, reason}}
            end
          {:error, reason} ->
            {:error, {:fetch_error, reason}}
        end
    end
  end

  defp do_refresh_all do
    list_feeds()
    |> Enum.each(fn {feed_id, feed} ->
      Task.start(fn ->
        fetch_and_parse_feed(feed_id, feed)
      end)
    end)
  end

  defp fetch_and_parse_feed(feed_id, feed) do
    case fetch_feed(feed.url) do
      {:ok, content} ->
        case parse_feed(content) do
          {:ok, parsed} ->
            updated_feed = %{feed |
              last_fetched: DateTime.utc_now(),
              error: nil
            }
            :ets.insert(@table_name, {feed_id, updated_feed})
            store_entries(feed_id, parsed.entries)
            :ok
          {:error, reason} ->
            updated_feed = %{feed | error: "Parse error: #{inspect(reason)}"}
            :ets.insert(@table_name, {feed_id, updated_feed})
            {:error, {:parse_error, reason}}
        end
      {:error, reason} ->
        updated_feed = %{feed | error: "Fetch error: #{inspect(reason)}"}
        :ets.insert(@table_name, {feed_id, updated_feed})
        {:error, {:fetch_error, reason}}
    end
  end

  defp fetch_feed(url) do
    # Use httpc for HTTP requests
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    url_charlist = String.to_charlist(url)

    http_options = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3
      ],
      timeout: @fetch_timeout,
      connect_timeout: 5000
    ]

    options = [
      body_format: :binary
    ]

    case :httpc.request(:get, {url_charlist, []}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}
      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}
      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp parse_feed(content) when is_binary(content) do
    cond do
      String.contains?(content, "<rss") -> parse_rss(content)
      String.contains?(content, "<feed") -> parse_atom(content)
      true -> {:error, :unknown_format}
    end
  end

  defp parse_rss(content) do
    # Simple RSS 2.0 parser using regex (basic but functional)
    title = extract_first(content, ~r/<channel>.*?<title>(?:<!\[CDATA\[)?(.+?)(?:\]\]>)?<\/title>/s)

    entries = Regex.scan(~r/<item>(.*?)<\/item>/s, content)
      |> Enum.map(fn [_, item_content] ->
        %{
          id: extract_first(item_content, ~r/<guid.*?>(.*?)<\/guid>/s) ||
              extract_first(item_content, ~r/<link>(.*?)<\/link>/s) ||
              :crypto.hash(:md5, item_content) |> Base.encode16(case: :lower),
          title: extract_first(item_content, ~r/<title>(?:<!\[CDATA\[)?(.+?)(?:\]\]>)?<\/title>/s) || "Untitled",
          link: extract_first(item_content, ~r/<link>(.*?)<\/link>/s),
          summary: extract_first(item_content, ~r/<description>(?:<!\[CDATA\[)?(.+?)(?:\]\]>)?<\/description>/s),
          content: extract_first(item_content, ~r/<content:encoded>(?:<!\[CDATA\[)?(.+?)(?:\]\]>)?<\/content:encoded>/s),
          published_at: parse_date(extract_first(item_content, ~r/<pubDate>(.*?)<\/pubDate>/s))
        }
      end)
      |> Enum.take(@max_entries_per_feed)

    {:ok, %{title: title, entries: entries}}
  end

  defp parse_atom(content) do
    title = extract_first(content, ~r/<feed.*?<title.*?>(.*?)<\/title>/s)

    entries = Regex.scan(~r/<entry>(.*?)<\/entry>/s, content)
      |> Enum.map(fn [_, entry_content] ->
        %{
          id: extract_first(entry_content, ~r/<id>(.*?)<\/id>/s) ||
              :crypto.hash(:md5, entry_content) |> Base.encode16(case: :lower),
          title: extract_first(entry_content, ~r/<title.*?>(.*?)<\/title>/s) || "Untitled",
          link: extract_link(entry_content),
          summary: extract_first(entry_content, ~r/<summary.*?>(.*?)<\/summary>/s),
          content: extract_first(entry_content, ~r/<content.*?>(.*?)<\/content>/s),
          published_at: parse_date(
            extract_first(entry_content, ~r/<published>(.*?)<\/published>/s) ||
            extract_first(entry_content, ~r/<updated>(.*?)<\/updated>/s)
          )
        }
      end)
      |> Enum.take(@max_entries_per_feed)

    {:ok, %{title: title, entries: entries}}
  end

  defp extract_first(content, regex) do
    case Regex.run(regex, content) do
      [_, match] -> String.trim(match) |> unescape_html()
      _ -> nil
    end
  end

  defp extract_link(content) do
    # Try href attribute first (Atom style)
    case Regex.run(~r/<link[^>]*href="([^"]+)"[^>]*>/s, content) do
      [_, href] -> href
      _ ->
        # Fall back to link content
        extract_first(content, ~r/<link>(.*?)<\/link>/s)
    end
  end

  defp parse_date(nil), do: nil
  defp parse_date(date_str) do
    date_str = String.trim(date_str)

    # Try various date formats
    parsers = [
      # ISO 8601
      fn d -> DateTime.from_iso8601(d) end,
      # RFC 2822 (common in RSS)
      fn d ->
        case Regex.run(~r/(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})/, d) do
          [_, day, month, year, hour, min, sec] ->
            month_num = month_to_number(month)
            if month_num do
              DateTime.new(
                Date.new!(String.to_integer(year), month_num, String.to_integer(day)),
                Time.new!(String.to_integer(hour), String.to_integer(min), String.to_integer(sec))
              )
            else
              {:error, :invalid_month}
            end
          _ -> {:error, :no_match}
        end
      end
    ]

    Enum.find_value(parsers, fn parser ->
      case parser.(date_str) do
        {:ok, datetime} -> datetime
        {:ok, datetime, _offset} -> datetime
        _ -> nil
      end
    end)
  end

  defp month_to_number(month) do
    months = %{
      "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4,
      "may" => 5, "jun" => 6, "jul" => 7, "aug" => 8,
      "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12
    }
    Map.get(months, String.downcase(String.slice(month, 0, 3)))
  end

  defp unescape_html(nil), do: nil
  defp unescape_html(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace(~r/<[^>]+>/, "")  # Strip HTML tags
  end

  defp escape_xml(nil), do: ""
  defp escape_xml(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp store_entries(feed_id, entries) do
    # Clear old entries for this feed
    :ets.match_delete(@entries_table, {feed_id, :_, :_})

    # Store new entries
    Enum.each(entries, fn entry ->
      entry_with_feed = Map.put(entry, :feed_id, feed_id)
      :ets.insert(@entries_table, {feed_id, entry.id, entry_with_feed})
    end)
  end

  defp generate_feed_id(url) do
    :crypto.hash(:md5, url) |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end
end
