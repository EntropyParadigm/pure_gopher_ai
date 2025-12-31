defmodule PureGopherAi.UserProfiles do
  @moduledoc """
  User profiles/homepages for the Gopher community.

  Features:
  - Create and manage personal profiles
  - Bio, links, interests
  - Rate limiting on creation
  - Admin moderation
  """

  use GenServer
  require Logger

  @table_name :user_profiles
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_bio_length 500
  @max_links 10
  @max_interests 10
  @username_min_length 3
  @username_max_length 20
  @cooldown_ms 86400_000  # 1 day between profile creations per IP

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new user profile.

  Options:
  - `:bio` - Short biography (max 500 chars)
  - `:links` - List of {title, url} tuples (max 10)
  - `:interests` - List of interest strings (max 10)
  """
  def create(username, ip, opts \\ []) do
    GenServer.call(__MODULE__, {:create, username, ip, opts})
  end

  @doc """
  Gets a user profile by username.
  """
  def get(username) do
    GenServer.call(__MODULE__, {:get, username})
  end

  @doc """
  Updates a user profile. Only the creator IP can update.
  """
  def update(username, ip, updates) do
    GenServer.call(__MODULE__, {:update, username, ip, updates})
  end

  @doc """
  Lists all profiles (paginated).
  """
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc """
  Searches profiles by username or interests.
  """
  def search(query) do
    GenServer.call(__MODULE__, {:search, query})
  end

  @doc """
  Deletes a profile (admin only).
  """
  def delete(username) do
    GenServer.call(__MODULE__, {:delete, username})
  end

  @doc """
  Gets profile statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "user_profiles.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Track cooldowns in ETS
    :ets.new(:profile_cooldowns, [:named_table, :public, :set])

    Logger.info("[UserProfiles] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, username, ip, opts}, _from, state) do
    ip_hash = hash_ip(ip)
    now = System.system_time(:millisecond)
    username_lower = String.downcase(username)

    cond do
      # Rate limit check
      check_cooldown(ip_hash, now) == :rate_limited ->
        {:reply, {:error, :rate_limited}, state}

      # Validate username
      not valid_username?(username) ->
        {:reply, {:error, :invalid_username}, state}

      String.length(username) < @username_min_length ->
        {:reply, {:error, :username_too_short}, state}

      String.length(username) > @username_max_length ->
        {:reply, {:error, :username_too_long}, state}

      # Check if username already exists
      username_exists?(username_lower) ->
        {:reply, {:error, :username_taken}, state}

      true ->
        bio = opts
          |> Keyword.get(:bio, "")
          |> String.slice(0, @max_bio_length)
          |> sanitize_text()

        links = opts
          |> Keyword.get(:links, [])
          |> Enum.take(@max_links)
          |> Enum.map(fn {title, url} ->
            {sanitize_text(title), sanitize_text(url)}
          end)

        interests = opts
          |> Keyword.get(:interests, [])
          |> Enum.take(@max_interests)
          |> Enum.map(&sanitize_text/1)

        profile = %{
          username: username,
          username_lower: username_lower,
          bio: bio,
          links: links,
          interests: interests,
          ip_hash: ip_hash,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          views: 0
        }

        :dets.insert(@table_name, {username_lower, profile})
        :dets.sync(@table_name)

        # Update cooldown
        :ets.insert(:profile_cooldowns, {ip_hash, now})

        Logger.info("[UserProfiles] Created profile: #{username}")
        {:reply, {:ok, username}, state}
    end
  end

  @impl true
  def handle_call({:get, username}, _from, state) do
    username_lower = String.downcase(username)

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        # Increment view count
        updated = %{profile | views: profile.views + 1}
        :dets.insert(@table_name, {username_lower, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update, username, ip, updates}, _from, state) do
    username_lower = String.downcase(username)
    ip_hash = hash_ip(ip)

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        if profile.ip_hash == ip_hash do
          updated = profile
            |> maybe_update(:bio, updates, @max_bio_length)
            |> maybe_update_links(updates)
            |> maybe_update_interests(updates)
            |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

          :dets.insert(@table_name, {username_lower, updated})
          :dets.sync(@table_name)

          Logger.info("[UserProfiles] Updated profile: #{username}")
          {:reply, {:ok, updated}, state}
        else
          {:reply, {:error, :unauthorized}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    profiles = :dets.foldl(fn {_key, profile}, acc ->
      [profile | acc]
    end, [], @table_name)

    sorted = profiles
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(fn p -> Map.drop(p, [:ip_hash]) end)

    {:reply, {:ok, sorted, length(profiles)}, state}
  end

  @impl true
  def handle_call({:search, query}, _from, state) do
    query_lower = String.downcase(query)

    results = :dets.foldl(fn {_key, profile}, acc ->
      matches_username = String.contains?(profile.username_lower, query_lower)
      matches_interests = Enum.any?(profile.interests, fn i ->
        String.contains?(String.downcase(i), query_lower)
      end)

      if matches_username or matches_interests do
        [Map.drop(profile, [:ip_hash]) | acc]
      else
        acc
      end
    end, [], @table_name)

    {:reply, {:ok, Enum.take(results, 20)}, state}
  end

  @impl true
  def handle_call({:delete, username}, _from, state) do
    username_lower = String.downcase(username)

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, _}] ->
        :dets.delete(@table_name, username_lower)
        :dets.sync(@table_name)
        Logger.info("[UserProfiles] Deleted profile: #{username}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {total, total_views} =
      :dets.foldl(fn {_key, profile}, {t, v} ->
        {t + 1, v + profile.views}
      end, {0, 0}, @table_name)

    {:reply, %{
      total_profiles: total,
      total_views: total_views
    }, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp hash_ip(ip) when is_tuple(ip) do
    ip_str = case ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
    end
    :crypto.hash(:sha256, ip_str) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp hash_ip(_), do: "unknown"

  defp check_cooldown(ip_hash, now) do
    case :ets.lookup(:profile_cooldowns, ip_hash) do
      [{^ip_hash, last_create}] when now - last_create < @cooldown_ms ->
        :rate_limited
      _ ->
        :ok
    end
  end

  defp valid_username?(username) do
    # Alphanumeric and underscores only
    Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_]*$/, username)
  end

  defp username_exists?(username_lower) do
    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, _}] -> true
      [] -> false
    end
  end

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")  # Strip HTML tags
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")  # Strip control chars
    |> String.trim()
  end

  defp sanitize_text(_), do: ""

  defp maybe_update(profile, field, updates, max_length) do
    case Keyword.get(updates, field) do
      nil -> profile
      value ->
        Map.put(profile, field, value |> String.slice(0, max_length) |> sanitize_text())
    end
  end

  defp maybe_update_links(profile, updates) do
    case Keyword.get(updates, :links) do
      nil -> profile
      links ->
        sanitized = links
          |> Enum.take(@max_links)
          |> Enum.map(fn {title, url} ->
            {sanitize_text(title), sanitize_text(url)}
          end)
        Map.put(profile, :links, sanitized)
    end
  end

  defp maybe_update_interests(profile, updates) do
    case Keyword.get(updates, :interests) do
      nil -> profile
      interests ->
        sanitized = interests
          |> Enum.take(@max_interests)
          |> Enum.map(&sanitize_text/1)
        Map.put(profile, :interests, sanitized)
    end
  end
end
