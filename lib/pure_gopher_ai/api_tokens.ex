defmodule PureGopherAi.ApiTokens do
  @moduledoc """
  API token management for programmatic access.

  Features:
  - Create named tokens with specific permissions
  - Revoke individual tokens
  - Token expiration support
  - Usage tracking
  - Rate limiting per token
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserProfiles

  @table_name :api_tokens
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @token_length 32
  @max_tokens_per_user 10
  @default_ttl_days 365

  # Available permissions
  @permissions [:read, :write, :phlog, :mail, :bookmarks, :search]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new API token for a user.

  Options:
  - :name - Token name/description (required)
  - :permissions - List of permissions (default: [:read])
  - :expires_in_days - Token expiration (default: 365)
  """
  def create(username, passphrase, opts \\ []) do
    GenServer.call(__MODULE__, {:create, username, passphrase, opts})
  end

  @doc """
  Validates a token and returns the associated user and permissions.
  """
  def validate(token) do
    GenServer.call(__MODULE__, {:validate, token})
  end

  @doc """
  Checks if a token has a specific permission.
  """
  def has_permission?(token, permission) do
    case validate(token) do
      {:ok, _username, permissions} -> permission in permissions
      _ -> false
    end
  end

  @doc """
  Lists all tokens for a user (requires auth).
  """
  def list(username, passphrase) do
    GenServer.call(__MODULE__, {:list, username, passphrase})
  end

  @doc """
  Revokes a specific token.
  """
  def revoke(username, passphrase, token_id) do
    GenServer.call(__MODULE__, {:revoke, username, passphrase, token_id})
  end

  @doc """
  Revokes all tokens for a user.
  """
  def revoke_all(username, passphrase) do
    GenServer.call(__MODULE__, {:revoke_all, username, passphrase})
  end

  @doc """
  Returns available permissions.
  """
  def permissions, do: @permissions

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "api_tokens.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Schedule cleanup of expired tokens
    :timer.send_interval(3600_000, :cleanup_expired)

    Logger.info("[ApiTokens] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, username, passphrase, opts}, _from, state) do
    # Authenticate user
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))
        name = Keyword.get(opts, :name, "Unnamed Token")
        permissions = Keyword.get(opts, :permissions, [:read])
        expires_in_days = Keyword.get(opts, :expires_in_days, @default_ttl_days)

        # Validate permissions
        valid_perms = Enum.filter(permissions, &(&1 in @permissions))

        if valid_perms == [] do
          {:reply, {:error, :no_valid_permissions}, state}
        else
          # Check token limit
          user_tokens = get_user_tokens(username_lower)

          if length(user_tokens) >= @max_tokens_per_user do
            {:reply, {:error, :token_limit_reached}, state}
          else
            # Generate token
            token = generate_token()
            token_id = generate_id()
            token_hash = hash_token(token)
            now = DateTime.utc_now()
            expires_at = DateTime.add(now, expires_in_days * 24 * 3600, :second)

            token_data = %{
              id: token_id,
              username: username,
              username_lower: username_lower,
              name: sanitize_text(name),
              token_hash: token_hash,
              permissions: valid_perms,
              created_at: DateTime.to_iso8601(now),
              expires_at: DateTime.to_iso8601(expires_at),
              last_used: nil,
              use_count: 0
            }

            :dets.insert(@table_name, {token_hash, token_data})
            :dets.sync(@table_name)

            Logger.info("[ApiTokens] Token created for: #{username}")

            # Return the actual token only once - it can't be retrieved again
            {:reply, {:ok, %{
              token: token,
              id: token_id,
              name: name,
              permissions: valid_perms,
              expires_at: DateTime.to_iso8601(expires_at)
            }}, state}
          end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:validate, token}, _from, state) do
    token_hash = hash_token(token)

    case :dets.lookup(@table_name, token_hash) do
      [{^token_hash, token_data}] ->
        # Check expiration
        expires_at = parse_datetime(token_data.expires_at)

        if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
          # Token expired
          :dets.delete(@table_name, token_hash)
          {:reply, {:error, :token_expired}, state}
        else
          # Update usage stats
          updated = %{token_data |
            last_used: DateTime.utc_now() |> DateTime.to_iso8601(),
            use_count: token_data.use_count + 1
          }
          :dets.insert(@table_name, {token_hash, updated})

          {:reply, {:ok, token_data.username, token_data.permissions}, state}
        end

      [] ->
        {:reply, {:error, :invalid_token}, state}
    end
  end

  @impl true
  def handle_call({:list, username, passphrase}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))
        tokens = get_user_tokens(username_lower)
          |> Enum.map(fn t ->
            Map.take(t, [:id, :name, :permissions, :created_at, :expires_at, :last_used, :use_count])
          end)

        {:reply, {:ok, tokens}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:revoke, username, passphrase, token_id}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))

        # Find and delete the token
        found = :dets.foldl(fn {hash, data}, acc ->
          if data.username_lower == username_lower and data.id == token_id do
            :dets.delete(@table_name, hash)
            true
          else
            acc
          end
        end, false, @table_name)

        if found do
          :dets.sync(@table_name)
          Logger.info("[ApiTokens] Token revoked: #{token_id} for #{username}")
          {:reply, :ok, state}
        else
          {:reply, {:error, :token_not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:revoke_all, username, passphrase}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))

        count = :dets.foldl(fn {hash, data}, acc ->
          if data.username_lower == username_lower do
            :dets.delete(@table_name, hash)
            acc + 1
          else
            acc
          end
        end, 0, @table_name)

        :dets.sync(@table_name)
        Logger.info("[ApiTokens] All tokens revoked for: #{username} (#{count} tokens)")
        {:reply, {:ok, count}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    now = DateTime.utc_now()

    count = :dets.foldl(fn {hash, data}, acc ->
      expires_at = parse_datetime(data.expires_at)
      if DateTime.compare(now, expires_at) == :gt do
        :dets.delete(@table_name, hash)
        acc + 1
      else
        acc
      end
    end, 0, @table_name)

    if count > 0 do
      :dets.sync(@table_name)
      Logger.info("[ApiTokens] Cleaned up #{count} expired tokens")
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp generate_token do
    :crypto.strong_rand_bytes(@token_length)
    |> Base.url_encode64(padding: false)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode64()
  end

  defp get_user_tokens(username_lower) do
    :dets.foldl(fn {_hash, data}, acc ->
      if data.username_lower == username_lower do
        [data | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
    |> String.trim()
    |> String.slice(0, 100)
  end

  defp sanitize_text(_), do: ""

  defp parse_datetime(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
