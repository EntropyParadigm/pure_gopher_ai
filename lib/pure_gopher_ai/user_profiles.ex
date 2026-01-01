defmodule PureGopherAi.UserProfiles do
  @moduledoc """
  User profiles/homepages for the Gopher community.

  Features:
  - Create and manage personal profiles
  - Passphrase-based authentication (works over Tor/VPN/NAT)
  - Bio, links, interests
  - Rate limiting on creation
  - Admin moderation
  """

  use GenServer
  require Logger

  alias PureGopherAi.PasswordValidator
  alias PureGopherAi.Recovery
  alias PureGopherAi.Totp

  @table_name :user_profiles
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_bio_length 500
  @max_links 10
  @max_interests 10
  @username_min_length 3
  @username_max_length 20
  @cooldown_ms 86400_000  # 1 day between profile creations per IP
  @pbkdf2_iterations 100_000
  @max_auth_failures_per_ip 5
  @auth_failure_window_ms 60_000  # 1 minute

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new user profile with passphrase authentication.

  Options:
  - `:bio` - Short biography (max 500 chars)
  - `:links` - List of {title, url} tuples (max 10)
  - `:interests` - List of interest strings (max 10)
  """
  def create(username, passphrase, ip, opts \\ []) do
    GenServer.call(__MODULE__, {:create, username, passphrase, ip, opts})
  end

  @doc """
  Authenticates a user with username and passphrase.
  Returns {:ok, profile} or {:error, reason}.
  """
  def authenticate(username, passphrase, ip \\ nil) do
    GenServer.call(__MODULE__, {:authenticate, username, passphrase, ip})
  end

  @doc """
  Recovers an account using recovery phrase.
  Resets the passphrase if the recovery phrase is valid.
  Returns {:ok, new_recovery_words} or {:error, reason}.
  """
  def recover(username, recovery_words, new_passphrase) when is_list(recovery_words) do
    GenServer.call(__MODULE__, {:recover, username, recovery_words, new_passphrase})
  end

  def recover(username, recovery_input, new_passphrase) when is_binary(recovery_input) do
    case Recovery.parse_input(recovery_input) do
      {:ok, words} -> recover(username, words, new_passphrase)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets a user profile by username.
  """
  def get(username) do
    GenServer.call(__MODULE__, {:get, username})
  end

  @doc """
  Updates a user profile. Requires passphrase authentication.
  """
  def update(username, passphrase, updates) do
    GenServer.call(__MODULE__, {:update, username, passphrase, updates})
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

  @doc """
  Initiates TOTP setup for a user. Returns secret and backup codes.
  TOTP is not active until confirmed with a valid code.
  """
  def setup_totp(username, passphrase) do
    GenServer.call(__MODULE__, {:setup_totp, username, passphrase})
  end

  @doc """
  Confirms TOTP setup with a valid code. Activates 2FA for the account.
  """
  def confirm_totp(username, passphrase, code) do
    GenServer.call(__MODULE__, {:confirm_totp, username, passphrase, code})
  end

  @doc """
  Disables TOTP for a user. Requires passphrase and valid TOTP code.
  """
  def disable_totp(username, passphrase, code) do
    GenServer.call(__MODULE__, {:disable_totp, username, passphrase, code})
  end

  @doc """
  Checks if a user has TOTP enabled.
  """
  def totp_enabled?(username) do
    GenServer.call(__MODULE__, {:totp_enabled, username})
  end

  @doc """
  Verifies a TOTP code for a user (used during login).
  Also accepts backup codes.
  """
  def verify_totp(username, code) do
    GenServer.call(__MODULE__, {:verify_totp, username, code})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "user_profiles.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Track cooldowns in ETS (for profile creation rate limiting)
    :ets.new(:profile_cooldowns, [:named_table, :public, :set])

    # Track auth failures in ETS (for brute force protection)
    :ets.new(:profile_auth_failures, [:named_table, :public, :set])

    Logger.info("[UserProfiles] Started with passphrase authentication")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, username, passphrase, ip, opts}, _from, state) do
    ip_hash = hash_ip(ip)
    now = System.system_time(:millisecond)
    username_lower = String.downcase(String.trim(username))

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

      # Validate passphrase strength
      match?({:error, _}, PasswordValidator.validate(passphrase)) ->
        {:error, reason} = PasswordValidator.validate(passphrase)
        {:reply, {:error, {:passphrase_weak, reason}}, state}

      # Check if username already exists
      username_exists?(username_lower) ->
        {:reply, {:error, :username_taken}, state}

      true ->
        # Generate salt and hash passphrase
        salt = :crypto.strong_rand_bytes(16)
        passphrase_hash = hash_passphrase(passphrase, salt)

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

        # Generate recovery phrase
        recovery_words = Recovery.generate_phrase()
        recovery_hash = Recovery.hash_phrase(recovery_words)

        profile = %{
          username: username,
          username_lower: username_lower,
          passphrase_hash: passphrase_hash,
          salt: salt,
          recovery_hash: recovery_hash,
          bio: bio,
          links: links,
          interests: interests,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          views: 0
        }

        :dets.insert(@table_name, {username_lower, profile})
        :dets.sync(@table_name)

        # Update cooldown
        :ets.insert(:profile_cooldowns, {ip_hash, now})

        Logger.info("[UserProfiles] Created profile: #{username}")
        {:reply, {:ok, username, recovery_words}, state}
    end
  end

  @impl true
  def handle_call({:authenticate, username, passphrase, ip}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    ip_hash = if ip, do: hash_ip(ip), else: nil

    # Check brute force protection
    if ip_hash && auth_rate_limited?(ip_hash) do
      {:reply, {:error, :too_many_attempts}, state}
    else
      case :dets.lookup(@table_name, username_lower) do
        [{^username_lower, profile}] ->
          expected_hash = hash_passphrase(passphrase, profile.salt)

          if secure_compare(expected_hash, profile.passphrase_hash) do
            # Clear auth failures on success
            if ip_hash, do: :ets.delete(:profile_auth_failures, ip_hash)
            {:reply, {:ok, Map.drop(profile, [:passphrase_hash, :salt, :recovery_hash])}, state}
          else
            # Record auth failure
            if ip_hash, do: record_auth_failure(ip_hash)
            {:reply, {:error, :invalid_credentials}, state}
          end

        [] ->
          # Record auth failure even for non-existent users (prevent enumeration)
          if ip_hash, do: record_auth_failure(ip_hash)
          {:reply, {:error, :invalid_credentials}, state}
      end
    end
  end

  @impl true
  def handle_call({:recover, username, recovery_words, new_passphrase}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        # Check if account has recovery phrase
        recovery_hash = Map.get(profile, :recovery_hash)

        cond do
          is_nil(recovery_hash) ->
            {:reply, {:error, :no_recovery_available}, state}

          not Recovery.verify_phrase(recovery_words, recovery_hash) ->
            {:reply, {:error, :invalid_recovery_phrase}, state}

          match?({:error, _}, PasswordValidator.validate(new_passphrase)) ->
            {:error, reason} = PasswordValidator.validate(new_passphrase)
            {:reply, {:error, {:passphrase_weak, reason}}, state}

          true ->
            # Generate new salt and hash new passphrase
            new_salt = :crypto.strong_rand_bytes(16)
            new_passphrase_hash = hash_passphrase(new_passphrase, new_salt)

            # Generate new recovery phrase
            new_recovery_words = Recovery.generate_phrase()
            new_recovery_hash = Recovery.hash_phrase(new_recovery_words)

            updated = %{profile |
              passphrase_hash: new_passphrase_hash,
              salt: new_salt,
              recovery_hash: new_recovery_hash,
              updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }

            :dets.insert(@table_name, {username_lower, updated})
            :dets.sync(@table_name)

            Logger.info("[UserProfiles] Account recovered: #{username}")
            {:reply, {:ok, new_recovery_words}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get, username}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        # Increment view count
        updated = %{profile | views: profile.views + 1}
        :dets.insert(@table_name, {username_lower, updated})
        # Don't expose sensitive fields
        {:reply, {:ok, Map.drop(updated, [:passphrase_hash, :salt, :recovery_hash])}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update, username, passphrase, updates}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        # Verify passphrase
        expected_hash = hash_passphrase(passphrase, profile.salt)

        if secure_compare(expected_hash, profile.passphrase_hash) do
          updated = profile
            |> maybe_update(:bio, updates, @max_bio_length)
            |> maybe_update_links(updates)
            |> maybe_update_interests(updates)
            |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

          :dets.insert(@table_name, {username_lower, updated})
          :dets.sync(@table_name)

          Logger.info("[UserProfiles] Updated profile: #{username}")
          {:reply, {:ok, Map.drop(updated, [:passphrase_hash, :salt, :recovery_hash])}, state}
        else
          {:reply, {:error, :invalid_credentials}, state}
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
      |> Enum.map(fn p -> Map.drop(p, [:passphrase_hash, :salt, :recovery_hash]) end)

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
        [Map.drop(profile, [:passphrase_hash, :salt, :recovery_hash]) | acc]
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
  def handle_call({:setup_totp, username, passphrase}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        # Verify passphrase
        expected_hash = hash_passphrase(passphrase, profile.salt)

        if secure_compare(expected_hash, profile.passphrase_hash) do
          # Check if TOTP already enabled
          if Map.get(profile, :totp_enabled, false) do
            {:reply, {:error, :totp_already_enabled}, state}
          else
            # Generate new TOTP secret and backup codes
            secret = Totp.generate_secret()
            backup_codes = Totp.generate_backup_codes()
            hashed_backups = Totp.hash_backup_codes(backup_codes)

            # Store pending TOTP (not active until confirmed)
            updated = Map.merge(profile, %{
              totp_pending_secret: secret,
              totp_pending_backups: hashed_backups,
              updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
            })

            :dets.insert(@table_name, {username_lower, updated})
            :dets.sync(@table_name)

            setup_text = Totp.setup_text(secret, username)
            {:reply, {:ok, secret, backup_codes, setup_text}, state}
          end
        else
          {:reply, {:error, :invalid_credentials}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:confirm_totp, username, passphrase, code}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        # Verify passphrase
        expected_hash = hash_passphrase(passphrase, profile.salt)

        cond do
          not secure_compare(expected_hash, profile.passphrase_hash) ->
            {:reply, {:error, :invalid_credentials}, state}

          is_nil(Map.get(profile, :totp_pending_secret)) ->
            {:reply, {:error, :no_pending_totp}, state}

          not Totp.validate(profile.totp_pending_secret, code) ->
            {:reply, {:error, :invalid_totp_code}, state}

          true ->
            # Activate TOTP
            updated = profile
              |> Map.put(:totp_secret, profile.totp_pending_secret)
              |> Map.put(:totp_backup_codes, profile.totp_pending_backups)
              |> Map.put(:totp_enabled, true)
              |> Map.delete(:totp_pending_secret)
              |> Map.delete(:totp_pending_backups)
              |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

            :dets.insert(@table_name, {username_lower, updated})
            :dets.sync(@table_name)

            Logger.info("[UserProfiles] TOTP enabled for: #{username}")
            {:reply, :ok, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:disable_totp, username, passphrase, code}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        # Verify passphrase
        expected_hash = hash_passphrase(passphrase, profile.salt)

        cond do
          not secure_compare(expected_hash, profile.passphrase_hash) ->
            {:reply, {:error, :invalid_credentials}, state}

          not Map.get(profile, :totp_enabled, false) ->
            {:reply, {:error, :totp_not_enabled}, state}

          not Totp.validate(profile.totp_secret, code) ->
            {:reply, {:error, :invalid_totp_code}, state}

          true ->
            # Disable TOTP
            updated = profile
              |> Map.delete(:totp_secret)
              |> Map.delete(:totp_backup_codes)
              |> Map.put(:totp_enabled, false)
              |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

            :dets.insert(@table_name, {username_lower, updated})
            :dets.sync(@table_name)

            Logger.info("[UserProfiles] TOTP disabled for: #{username}")
            {:reply, :ok, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:totp_enabled, username}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        {:reply, Map.get(profile, :totp_enabled, false), state}

      [] ->
        {:reply, false, state}
    end
  end

  @impl true
  def handle_call({:verify_totp, username, code}, _from, state) do
    username_lower = String.downcase(String.trim(username))

    case :dets.lookup(@table_name, username_lower) do
      [{^username_lower, profile}] ->
        cond do
          not Map.get(profile, :totp_enabled, false) ->
            {:reply, {:error, :totp_not_enabled}, state}

          # Try TOTP code first
          Totp.validate(profile.totp_secret, code) ->
            {:reply, :ok, state}

          # Try backup code
          true ->
            backup_codes = Map.get(profile, :totp_backup_codes, [])
            case Totp.validate_backup_code(code, backup_codes) do
              {:ok, remaining} ->
                # Update remaining backup codes
                updated = %{profile | totp_backup_codes: remaining}
                :dets.insert(@table_name, {username_lower, updated})
                :dets.sync(@table_name)
                Logger.info("[UserProfiles] Backup code used for: #{username}")
                {:reply, {:ok, :backup_code_used, length(remaining)}, state}

              {:error, :invalid_code} ->
                {:reply, {:error, :invalid_totp_code}, state}
            end
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
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

  # Passphrase hashing using PBKDF2
  defp hash_passphrase(passphrase, salt) do
    :crypto.pbkdf2_hmac(:sha256, passphrase, salt, @pbkdf2_iterations, 32)
    |> Base.encode64()
  end

  # Timing-safe comparison to prevent timing attacks
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false

  # Auth failure rate limiting
  defp auth_rate_limited?(ip_hash) do
    now = System.system_time(:millisecond)

    case :ets.lookup(:profile_auth_failures, ip_hash) do
      [{^ip_hash, failures, first_failure}] ->
        # Check if within window and over limit
        if now - first_failure < @auth_failure_window_ms do
          failures >= @max_auth_failures_per_ip
        else
          # Window expired, reset
          :ets.delete(:profile_auth_failures, ip_hash)
          false
        end

      [] ->
        false
    end
  end

  defp record_auth_failure(ip_hash) do
    now = System.system_time(:millisecond)

    case :ets.lookup(:profile_auth_failures, ip_hash) do
      [{^ip_hash, failures, first_failure}] ->
        if now - first_failure < @auth_failure_window_ms do
          # Within window, increment
          :ets.insert(:profile_auth_failures, {ip_hash, failures + 1, first_failure})
        else
          # Window expired, start new
          :ets.insert(:profile_auth_failures, {ip_hash, 1, now})
        end

      [] ->
        # First failure
        :ets.insert(:profile_auth_failures, {ip_hash, 1, now})
    end
  end
end
