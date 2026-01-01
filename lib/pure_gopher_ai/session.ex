defmodule PureGopherAi.Session do
  @moduledoc """
  Session token management for authenticated actions.

  Reduces passphrase exposure by issuing short-lived tokens after initial auth.
  Tokens are stored in ETS with automatic expiration.

  Flow:
  1. User authenticates with username:passphrase
  2. System issues a session token (valid 30 minutes)
  3. Subsequent requests use token instead of passphrase
  4. Token auto-expires or can be manually invalidated
  """

  use GenServer
  require Logger

  @table :session_tokens
  @default_ttl_ms 30 * 60 * 1000  # 30 minutes
  @cleanup_interval_ms 60 * 1000  # Clean expired every minute
  @token_length 32

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new session token for an authenticated user.
  Returns {:ok, token} on success.
  """
  def create(username, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    token = generate_token()
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    :ets.insert(@table, {token, %{
      username: username,
      created_at: DateTime.utc_now(),
      expires_at: expires_at,
      ip: Keyword.get(opts, :ip)
    }})

    Logger.debug("[Session] Created token for #{username}, expires in #{div(ttl_ms, 60_000)} min")
    {:ok, token}
  end

  @doc """
  Validates a session token.
  Returns {:ok, username} if valid, {:error, reason} otherwise.
  """
  def validate(token) do
    case :ets.lookup(@table, token) do
      [{^token, session}] ->
        now = System.monotonic_time(:millisecond)
        if now < session.expires_at do
          {:ok, session.username}
        else
          :ets.delete(@table, token)
          {:error, :expired}
        end

      [] ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Validates token and optionally checks IP matches.
  """
  def validate(token, ip) do
    case :ets.lookup(@table, token) do
      [{^token, session}] ->
        now = System.monotonic_time(:millisecond)
        cond do
          now >= session.expires_at ->
            :ets.delete(@table, token)
            {:error, :expired}

          session.ip != nil and session.ip != ip ->
            {:error, :ip_mismatch}

          true ->
            {:ok, session.username}
        end

      [] ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Refreshes a token's expiration time.
  Returns :ok on success, {:error, reason} on failure.
  """
  def refresh(token, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    case :ets.lookup(@table, token) do
      [{^token, session}] ->
        now = System.monotonic_time(:millisecond)
        if now < session.expires_at do
          new_expires = now + ttl_ms
          :ets.insert(@table, {token, %{session | expires_at: new_expires}})
          :ok
        else
          :ets.delete(@table, token)
          {:error, :expired}
        end

      [] ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Invalidates a session token (logout).
  """
  def invalidate(token) do
    :ets.delete(@table, token)
    :ok
  end

  @doc """
  Invalidates all sessions for a user.
  """
  def invalidate_all(username) do
    # Find all tokens for this user
    tokens = :ets.foldl(fn
      {token, %{username: ^username}}, acc -> [token | acc]
      _, acc -> acc
    end, [], @table)

    Enum.each(tokens, &:ets.delete(@table, &1))
    {:ok, length(tokens)}
  end

  @doc """
  Gets session info for a token (without validating expiration).
  """
  def get_info(token) do
    case :ets.lookup(@table, token) do
      [{^token, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns session statistics.
  """
  def stats do
    now = System.monotonic_time(:millisecond)

    {active, expired} = :ets.foldl(fn
      {_token, session}, {a, e} ->
        if now < session.expires_at, do: {a + 1, e}, else: {a, e + 1}
    end, {0, 0}, @table)

    %{
      active_sessions: active,
      expired_pending_cleanup: expired,
      total_entries: :ets.info(@table, :size)
    }
  end

  @doc """
  Authenticates user and creates session in one step.
  Requires UserProfiles module for passphrase verification.
  """
  def login(username, passphrase, opts \\ []) do
    alias PureGopherAi.UserProfiles

    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        create(username, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for sessions
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)

    Logger.info("[Session] Started with #{@default_ttl_ms}ms default TTL")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, state}
  end

  # Private functions

  defp generate_token do
    :crypto.strong_rand_bytes(@token_length)
    |> Base.url_encode64(padding: false)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    expired = :ets.foldl(fn
      {token, session}, acc ->
        if now >= session.expires_at, do: [token | acc], else: acc
    end, [], @table)

    Enum.each(expired, &:ets.delete(@table, &1))

    if length(expired) > 0 do
      Logger.debug("[Session] Cleaned up #{length(expired)} expired sessions")
    end
  end
end
