defmodule PureGopherAi.UserBlocks do
  @moduledoc """
  User blocking system for messaging and interactions.

  Allows users to:
  - Block other users from sending them messages
  - Block users from commenting on their content
  - Mute users (hide their content without blocking)
  """

  use GenServer
  require Logger

  @table :user_blocks
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_blocks_per_user 100

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Blocks a user. Requires authentication (caller must verify).
  """
  def block(blocker_username, blocked_username, opts \\ []) do
    GenServer.call(__MODULE__, {:block, blocker_username, blocked_username, opts})
  end

  @doc """
  Unblocks a user.
  """
  def unblock(blocker_username, blocked_username) do
    GenServer.call(__MODULE__, {:unblock, blocker_username, blocked_username})
  end

  @doc """
  Mutes a user (hides their content but doesn't block messaging).
  """
  def mute(muter_username, muted_username) do
    GenServer.call(__MODULE__, {:mute, muter_username, muted_username})
  end

  @doc """
  Unmutes a user.
  """
  def unmute(muter_username, muted_username) do
    GenServer.call(__MODULE__, {:unmute, muter_username, muted_username})
  end

  @doc """
  Checks if user A has blocked user B.
  """
  def blocked?(blocker_username, blocked_username) do
    GenServer.call(__MODULE__, {:blocked?, blocker_username, blocked_username})
  end

  @doc """
  Checks if user A has muted user B.
  """
  def muted?(muter_username, muted_username) do
    GenServer.call(__MODULE__, {:muted?, muter_username, muted_username})
  end

  @doc """
  Checks if a message can be sent from sender to recipient.
  Returns :ok or {:error, :blocked}.
  """
  def can_message?(sender_username, recipient_username) do
    if blocked?(recipient_username, sender_username) do
      {:error, :blocked}
    else
      :ok
    end
  end

  @doc """
  Checks if a user can comment on another's content.
  """
  def can_comment?(commenter_username, content_owner_username) do
    if blocked?(content_owner_username, commenter_username) do
      {:error, :blocked}
    else
      :ok
    end
  end

  @doc """
  Gets the list of users blocked by a user.
  """
  def list_blocked(username) do
    GenServer.call(__MODULE__, {:list_blocked, username})
  end

  @doc """
  Gets the list of users muted by a user.
  """
  def list_muted(username) do
    GenServer.call(__MODULE__, {:list_muted, username})
  end

  @doc """
  Gets users who have blocked a given user.
  """
  def blocked_by(username) do
    GenServer.call(__MODULE__, {:blocked_by, username})
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

    dets_file = Path.join(data_dir, "user_blocks.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: dets_file, type: :set)

    Logger.info("[UserBlocks] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:block, blocker, blocked, opts}, _from, state) do
    blocker_lower = normalize_username(blocker)
    blocked_lower = normalize_username(blocked)

    if blocker_lower == blocked_lower do
      {:reply, {:error, :cannot_block_self}, state}
    else
      data = get_user_data(blocker_lower)
      blocked_list = data.blocked

      cond do
        blocked_lower in blocked_list ->
          {:reply, {:error, :already_blocked}, state}

        length(blocked_list) >= @max_blocks_per_user ->
          {:reply, {:error, :block_limit_reached}, state}

        true ->
          reason = Keyword.get(opts, :reason, "")
          entry = %{
            username: blocked_lower,
            blocked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            reason: reason
          }

          updated = %{data |
            blocked: [entry | blocked_list],
            updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }

          :dets.insert(@table, {blocker_lower, updated})
          Logger.info("[UserBlocks] #{blocker} blocked #{blocked}")
          {:reply, :ok, state}
      end
    end
  end

  @impl true
  def handle_call({:unblock, blocker, blocked}, _from, state) do
    blocker_lower = normalize_username(blocker)
    blocked_lower = normalize_username(blocked)

    data = get_user_data(blocker_lower)
    blocked_list = data.blocked

    new_blocked = Enum.reject(blocked_list, fn
      %{username: u} -> u == blocked_lower
      u when is_binary(u) -> u == blocked_lower
    end)

    if length(new_blocked) == length(blocked_list) do
      {:reply, {:error, :not_blocked}, state}
    else
      updated = %{data |
        blocked: new_blocked,
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      :dets.insert(@table, {blocker_lower, updated})
      Logger.info("[UserBlocks] #{blocker} unblocked #{blocked}")
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:mute, muter, muted}, _from, state) do
    muter_lower = normalize_username(muter)
    muted_lower = normalize_username(muted)

    if muter_lower == muted_lower do
      {:reply, {:error, :cannot_mute_self}, state}
    else
      data = get_user_data(muter_lower)

      if muted_lower in data.muted do
        {:reply, {:error, :already_muted}, state}
      else
        updated = %{data |
          muted: [muted_lower | data.muted],
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :dets.insert(@table, {muter_lower, updated})
        {:reply, :ok, state}
      end
    end
  end

  @impl true
  def handle_call({:unmute, muter, muted}, _from, state) do
    muter_lower = normalize_username(muter)
    muted_lower = normalize_username(muted)

    data = get_user_data(muter_lower)

    if muted_lower in data.muted do
      updated = %{data |
        muted: List.delete(data.muted, muted_lower),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      :dets.insert(@table, {muter_lower, updated})
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_muted}, state}
    end
  end

  @impl true
  def handle_call({:blocked?, blocker, blocked}, _from, state) do
    blocker_lower = normalize_username(blocker)
    blocked_lower = normalize_username(blocked)

    data = get_user_data(blocker_lower)

    result = Enum.any?(data.blocked, fn
      %{username: u} -> u == blocked_lower
      u when is_binary(u) -> u == blocked_lower
    end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:muted?, muter, muted}, _from, state) do
    muter_lower = normalize_username(muter)
    muted_lower = normalize_username(muted)

    data = get_user_data(muter_lower)
    {:reply, muted_lower in data.muted, state}
  end

  @impl true
  def handle_call({:list_blocked, username}, _from, state) do
    username_lower = normalize_username(username)
    data = get_user_data(username_lower)

    blocked = Enum.map(data.blocked, fn
      %{username: _u} = entry -> entry
      u when is_binary(u) -> %{username: u, blocked_at: nil, reason: ""}
    end)

    {:reply, {:ok, blocked}, state}
  end

  @impl true
  def handle_call({:list_muted, username}, _from, state) do
    username_lower = normalize_username(username)
    data = get_user_data(username_lower)
    {:reply, {:ok, data.muted}, state}
  end

  @impl true
  def handle_call({:blocked_by, username}, _from, state) do
    username_lower = normalize_username(username)

    blockers = :dets.foldl(fn {blocker, data}, acc ->
      blocked_usernames = Enum.map(data.blocked, fn
        %{username: u} -> u
        u when is_binary(u) -> u
      end)

      if username_lower in blocked_usernames do
        [blocker | acc]
      else
        acc
      end
    end, [], @table)

    {:reply, {:ok, blockers}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = :dets.foldl(fn {_username, data}, acc ->
      acc
      |> Map.update(:total_users, 1, & &1 + 1)
      |> Map.update(:total_blocks, length(data.blocked), & &1 + length(data.blocked))
      |> Map.update(:total_mutes, length(data.muted), & &1 + length(data.muted))
    end, %{total_users: 0, total_blocks: 0, total_mutes: 0}, @table)

    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # Private functions

  defp normalize_username(username) do
    username |> String.trim() |> String.downcase()
  end

  defp get_user_data(username_lower) do
    case :dets.lookup(@table, username_lower) do
      [{^username_lower, data}] -> data
      [] -> %{blocked: [], muted: [], updated_at: nil}
    end
  end
end
