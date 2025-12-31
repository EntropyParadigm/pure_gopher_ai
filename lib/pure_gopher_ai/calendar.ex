defmodule PureGopherAi.Calendar do
  @moduledoc """
  Community event calendar.

  Features:
  - Create and manage events
  - View by day, week, month
  - Upcoming events list
  - Rate limiting
  - Admin moderation
  """

  use GenServer
  require Logger

  @table_name :calendar_events
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_title_length 100
  @max_description_length 500
  @max_location_length 100
  @cooldown_ms 300_000  # 5 minutes between event creations per IP

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new event.

  Required fields:
  - `:title` - Event title
  - `:date` - Date string (YYYY-MM-DD)

  Optional fields:
  - `:time` - Time string (HH:MM)
  - `:description` - Event description
  - `:location` - Event location
  """
  def create(ip, opts) do
    GenServer.call(__MODULE__, {:create, ip, opts})
  end

  @doc """
  Gets an event by ID.
  """
  def get(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc """
  Lists upcoming events (from today forward).
  """
  def list_upcoming(limit \\ 20) do
    GenServer.call(__MODULE__, {:list_upcoming, limit})
  end

  @doc """
  Lists events for a specific date.
  """
  def list_by_date(date) do
    GenServer.call(__MODULE__, {:list_by_date, date})
  end

  @doc """
  Lists events for a specific month.
  """
  def list_by_month(year, month) do
    GenServer.call(__MODULE__, {:list_by_month, year, month})
  end

  @doc """
  Deletes an event (admin only).
  """
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @doc """
  Gets calendar statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "calendar.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Track cooldowns in ETS
    :ets.new(:calendar_cooldowns, [:named_table, :public, :set])

    Logger.info("[Calendar] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, ip, opts}, _from, state) do
    ip_hash = hash_ip(ip)
    now = System.system_time(:millisecond)

    title = Keyword.get(opts, :title, "") |> String.trim()
    date_str = Keyword.get(opts, :date, "")
    time_str = Keyword.get(opts, :time, "")
    description = Keyword.get(opts, :description, "") |> String.trim()
    location = Keyword.get(opts, :location, "") |> String.trim()

    cond do
      # Rate limit check
      check_cooldown(ip_hash, now) == :rate_limited ->
        {:reply, {:error, :rate_limited}, state}

      # Validate title
      title == "" ->
        {:reply, {:error, :empty_title}, state}

      String.length(title) > @max_title_length ->
        {:reply, {:error, :title_too_long}, state}

      # Validate date
      not valid_date?(date_str) ->
        {:reply, {:error, :invalid_date}, state}

      # Validate time if provided
      time_str != "" and not valid_time?(time_str) ->
        {:reply, {:error, :invalid_time}, state}

      # Check description length
      String.length(description) > @max_description_length ->
        {:reply, {:error, :description_too_long}, state}

      # Check location length
      String.length(location) > @max_location_length ->
        {:reply, {:error, :location_too_long}, state}

      true ->
        id = generate_id()
        created_at = DateTime.utc_now() |> DateTime.to_iso8601()

        event = %{
          id: id,
          title: sanitize_text(title),
          date: date_str,
          time: if(time_str == "", do: nil, else: time_str),
          description: sanitize_text(description),
          location: sanitize_text(location),
          ip_hash: ip_hash,
          created_at: created_at
        }

        :dets.insert(@table_name, {id, event})
        :dets.sync(@table_name)

        # Update cooldown
        :ets.insert(:calendar_cooldowns, {ip_hash, now})

        Logger.info("[Calendar] Created event #{id}: #{title} on #{date_str}")
        {:reply, {:ok, id}, state}
    end
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, event}] ->
        {:reply, {:ok, Map.drop(event, [:ip_hash])}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_upcoming, limit}, _from, state) do
    today = Date.utc_today() |> Date.to_string()

    events = :dets.foldl(fn {_id, event}, acc ->
      if event.date >= today do
        [Map.drop(event, [:ip_hash]) | acc]
      else
        acc
      end
    end, [], @table_name)

    sorted = events
      |> Enum.sort_by(fn e -> {e.date, e.time || "00:00"} end, :asc)
      |> Enum.take(limit)

    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:list_by_date, date}, _from, state) do
    date_str = format_date_for_query(date)

    events = :dets.foldl(fn {_id, event}, acc ->
      if event.date == date_str do
        [Map.drop(event, [:ip_hash]) | acc]
      else
        acc
      end
    end, [], @table_name)

    sorted = events
      |> Enum.sort_by(fn e -> e.time || "00:00" end, :asc)

    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:list_by_month, year, month}, _from, state) do
    prefix = :io_lib.format("~4..0B-~2..0B", [year, month]) |> to_string()

    events = :dets.foldl(fn {_id, event}, acc ->
      if String.starts_with?(event.date, prefix) do
        [Map.drop(event, [:ip_hash]) | acc]
      else
        acc
      end
    end, [], @table_name)

    sorted = events
      |> Enum.sort_by(fn e -> {e.date, e.time || "00:00"} end, :asc)

    {:reply, {:ok, sorted}, state}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, _}] ->
        :dets.delete(@table_name, id)
        :dets.sync(@table_name)
        Logger.info("[Calendar] Deleted event #{id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    today = Date.utc_today() |> Date.to_string()

    {total, upcoming, this_month} =
      :dets.foldl(fn {_id, event}, {t, u, m} ->\
        is_upcoming = event.date >= today
        is_this_month = String.starts_with?(event.date, String.slice(today, 0, 7))

        {
          t + 1,
          u + (if is_upcoming, do: 1, else: 0),
          m + (if is_this_month, do: 1, else: 0)
        }
      end, {0, 0, 0}, @table_name)

    {:reply, %{
      total_events: total,
      upcoming_events: upcoming,
      events_this_month: this_month
    }, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
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
    case :ets.lookup(:calendar_cooldowns, ip_hash) do
      [{^ip_hash, last_create}] when now - last_create < @cooldown_ms ->
        :rate_limited
      _ ->
        :ok
    end
  end

  defp valid_date?(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_time?(time_str) do
    case Regex.match?(~r/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/, time_str) do
      true -> true
      false -> false
    end
  end

  defp format_date_for_query(date) when is_binary(date), do: date
  defp format_date_for_query(%Date{} = date), do: Date.to_string(date)

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")  # Strip HTML tags
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")  # Strip control chars
    |> String.trim()
  end

  defp sanitize_text(_), do: ""
end
