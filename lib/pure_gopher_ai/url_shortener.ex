defmodule PureGopherAi.UrlShortener do
  @moduledoc """
  Simple URL shortener for the Gopher community.

  Features:
  - Create short links for long URLs
  - Track click counts
  - Rate limiting
  - Admin moderation
  """

  use GenServer
  require Logger

  @table_name :short_urls
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_url_length 2000
  @cooldown_ms 60_000  # 1 minute between creations per IP
  @short_code_length 6

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a short URL.
  """
  def create(url, ip) do
    GenServer.call(__MODULE__, {:create, url, ip})
  end

  @doc """
  Gets the original URL from a short code.
  """
  def get(code) do
    GenServer.call(__MODULE__, {:get, code})
  end

  @doc """
  Gets full info about a short URL (including stats).
  """
  def info(code) do
    GenServer.call(__MODULE__, {:info, code})
  end

  @doc """
  Lists recent short URLs (public).
  """
  def list_recent(limit \\ 20) do
    GenServer.call(__MODULE__, {:list_recent, limit})
  end

  @doc """
  Deletes a short URL (admin only).
  """
  def delete(code) do
    GenServer.call(__MODULE__, {:delete, code})
  end

  @doc """
  Gets statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "short_urls.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Track cooldowns in ETS
    :ets.new(:url_shortener_cooldowns, [:named_table, :public, :set])

    Logger.info("[UrlShortener] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, url, ip}, _from, state) do
    ip_hash = hash_ip(ip)
    now = System.system_time(:millisecond)
    url = String.trim(url)

    cond do
      # Rate limit check
      check_cooldown(ip_hash, now) == :rate_limited ->
        {:reply, {:error, :rate_limited}, state}

      # Validate URL
      url == "" ->
        {:reply, {:error, :empty_url}, state}

      String.length(url) > @max_url_length ->
        {:reply, {:error, :url_too_long}, state}

      not valid_url?(url) ->
        {:reply, {:error, :invalid_url}, state}

      true ->
        code = generate_code()

        entry = %{
          code: code,
          url: url,
          clicks: 0,
          ip_hash: ip_hash,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :dets.insert(@table_name, {code, entry})
        :dets.sync(@table_name)

        # Update cooldown
        :ets.insert(:url_shortener_cooldowns, {ip_hash, now})

        Logger.info("[UrlShortener] Created #{code} -> #{truncate_url(url)}")
        {:reply, {:ok, code}, state}
    end
  end

  @impl true
  def handle_call({:get, code}, _from, state) do
    case :dets.lookup(@table_name, code) do
      [{^code, entry}] ->
        # Increment click count
        updated = %{entry | clicks: entry.clicks + 1}
        :dets.insert(@table_name, {code, updated})

        {:reply, {:ok, entry.url}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:info, code}, _from, state) do
    case :dets.lookup(@table_name, code) do
      [{^code, entry}] ->
        {:reply, {:ok, Map.drop(entry, [:ip_hash])}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_recent, limit}, _from, state) do
    entries = :dets.foldl(fn {_code, entry}, acc ->
      [Map.drop(entry, [:ip_hash]) | acc]
    end, [], @table_name)

    sorted = entries
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:delete, code}, _from, state) do
    case :dets.lookup(@table_name, code) do
      [{^code, _}] ->
        :dets.delete(@table_name, code)
        :dets.sync(@table_name)
        Logger.info("[UrlShortener] Deleted #{code}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {total, total_clicks} =
      :dets.foldl(fn {_code, entry}, {t, c} ->
        {t + 1, c + entry.clicks}
      end, {0, 0}, @table_name)

    {:reply, %{
      total_urls: total,
      total_clicks: total_clicks
    }, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp generate_code do
    :crypto.strong_rand_bytes(@short_code_length)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, @short_code_length)
    |> String.downcase()
  end

  defp hash_ip(ip) when is_tuple(ip) do
    ip_str = case ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
    end
    :crypto.hash(:sha256, ip_str) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp hash_ip(_), do: "unknown"

  defp check_cooldown(ip_hash, now) do
    case :ets.lookup(:url_shortener_cooldowns, ip_hash) do
      [{^ip_hash, last_create}] when now - last_create < @cooldown_ms ->
        :rate_limited
      _ ->
        :ok
    end
  end

  defp valid_url?(url) do
    # Accept common URL schemes
    String.match?(url, ~r/^(https?|gopher|gemini):\/\/.+/)
  end

  defp truncate_url(url) do
    if String.length(url) > 50 do
      String.slice(url, 0, 50) <> "..."
    else
      url
    end
  end
end
