defmodule PureGopherAi.Captcha do
  @moduledoc """
  CAPTCHA challenge system for high-risk actions on Tor.

  Uses simple text-based challenges suitable for Gopher protocol.
  Challenges are stored in ETS with a 5-minute TTL.
  """

  use GenServer
  require Logger

  @table :captcha_challenges
  @challenge_ttl_ms 5 * 60 * 1000  # 5 minutes
  @cleanup_interval_ms 60 * 1000   # 1 minute

  # Challenge types
  @challenges [
    {"What is 2 + 3?", "5"},
    {"What is 7 - 4?", "3"},
    {"What is 3 * 3?", "9"},
    {"What is 8 / 2?", "4"},
    {"Type 'gopher' backwards:", "rehpog"},
    {"Type the word 'hello':", "hello"},
    {"Type 'tor' in uppercase:", "TOR"},
    {"What comes after 'A'?", "B"},
    {"What comes before 'Z'?", "Y"},
    {"How many letters in 'cat'?", "3"},
    {"First letter of 'security':", "S"},
    {"Complete: go___r (hint: protocol)", "gopher"},
    {"Is the sky blue? (yes/no)", "yes"},
    {"Opposite of 'hot':", "cold"},
    {"What color is grass?", "green"}
  ]

  # Actions that require CAPTCHA on Tor
  @high_risk_actions [:register, :send_message, :create_post, :submit_guestbook, :create_poll]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if an action requires CAPTCHA for this network.
  """
  def required?(action, network) when network == :tor and action in @high_risk_actions do
    true
  end
  def required?(_action, _network), do: false

  @doc """
  Creates a new CAPTCHA challenge.
  Returns {challenge_id, question}
  """
  def create_challenge do
    GenServer.call(__MODULE__, :create_challenge)
  end

  @doc """
  Verifies a CAPTCHA response.
  Returns :ok or {:error, reason}
  """
  def verify(challenge_id, response) do
    GenServer.call(__MODULE__, {:verify, challenge_id, String.trim(response)})
  end

  @doc """
  Creates a pending action that requires CAPTCHA verification.
  Returns a token that can be used after CAPTCHA is solved.
  """
  def create_pending_action(action, params) do
    GenServer.call(__MODULE__, {:create_pending, action, params})
  end

  @doc """
  Gets the pending action for a token after CAPTCHA is verified.
  Returns {:ok, {action, params}} or {:error, :not_found}
  """
  def get_pending_action(token) do
    GenServer.call(__MODULE__, {:get_pending, token})
  end

  @doc """
  Marks a pending action as verified (CAPTCHA solved).
  """
  def mark_verified(challenge_id) do
    GenServer.call(__MODULE__, {:mark_verified, challenge_id})
  end

  @doc """
  Checks if a challenge has been verified.
  """
  def verified?(challenge_id) do
    GenServer.call(__MODULE__, {:is_verified, challenge_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    schedule_cleanup()
    Logger.info("[CAPTCHA] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call(:create_challenge, _from, state) do
    {question, answer} = Enum.random(@challenges)
    challenge_id = generate_id()
    expires_at = System.monotonic_time(:millisecond) + @challenge_ttl_ms

    :ets.insert(@table, {challenge_id, %{
      answer: String.downcase(answer),
      expires_at: expires_at,
      verified: false,
      pending_action: nil,
      pending_params: nil
    }})

    {:reply, {challenge_id, question}, state}
  end

  @impl true
  def handle_call({:verify, challenge_id, response}, _from, state) do
    now = System.monotonic_time(:millisecond)

    result = case :ets.lookup(@table, challenge_id) do
      [{^challenge_id, %{answer: answer, expires_at: expires_at}}] when expires_at > now ->
        if String.downcase(response) == answer do
          # Mark as verified but don't delete yet (allow action execution)
          case :ets.lookup(@table, challenge_id) do
            [{^challenge_id, challenge}] ->
              :ets.insert(@table, {challenge_id, %{challenge | verified: true}})
            _ ->
              :ok
          end
          :ok
        else
          {:error, :incorrect}
        end

      [{^challenge_id, _}] ->
        :ets.delete(@table, challenge_id)
        {:error, :expired}

      [] ->
        {:error, :not_found}
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:create_pending, action, params}, _from, state) do
    token = generate_id()
    {challenge_id, question} = create_challenge_internal()
    expires_at = System.monotonic_time(:millisecond) + @challenge_ttl_ms

    :ets.insert(@table, {token, %{
      type: :pending_action,
      action: action,
      params: params,
      challenge_id: challenge_id,
      expires_at: expires_at,
      verified: false
    }})

    {:reply, {:ok, token, challenge_id, question}, state}
  end

  @impl true
  def handle_call({:get_pending, token}, _from, state) do
    now = System.monotonic_time(:millisecond)

    result = case :ets.lookup(@table, token) do
      [{^token, %{type: :pending_action, action: action, params: params, verified: true, expires_at: expires_at}}]
          when expires_at > now ->
        # Consume the token
        :ets.delete(@table, token)
        {:ok, {action, params}}

      [{^token, %{type: :pending_action, verified: false}}] ->
        {:error, :not_verified}

      [{^token, _}] ->
        :ets.delete(@table, token)
        {:error, :expired}

      [] ->
        {:error, :not_found}
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:mark_verified, challenge_id}, _from, state) do
    # Find pending action with this challenge_id and mark it verified
    :ets.foldl(fn
      {token, %{type: :pending_action, challenge_id: ^challenge_id} = pending}, _acc ->
        :ets.insert(@table, {token, %{pending | verified: true}})
        :ok
      _, acc ->
        acc
    end, :not_found, @table)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:is_verified, challenge_id}, _from, state) do
    result = case :ets.lookup(@table, challenge_id) do
      [{^challenge_id, %{verified: true}}] -> true
      _ -> false
    end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp create_challenge_internal do
    {question, answer} = Enum.random(@challenges)
    challenge_id = generate_id()
    expires_at = System.monotonic_time(:millisecond) + @challenge_ttl_ms

    :ets.insert(@table, {challenge_id, %{
      answer: String.downcase(answer),
      expires_at: expires_at,
      verified: false
    }})

    {challenge_id, question}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    expired = :ets.foldl(fn
      {id, %{expires_at: expires_at}}, acc when expires_at < now -> [id | acc]
      _, acc -> acc
    end, [], @table)

    Enum.each(expired, &:ets.delete(@table, &1))

    if length(expired) > 0 do
      Logger.debug("[CAPTCHA] Cleaned up #{length(expired)} expired challenges")
    end
  end
end
