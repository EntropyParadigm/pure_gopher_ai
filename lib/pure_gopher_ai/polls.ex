defmodule PureGopherAi.Polls do
  @moduledoc """
  Simple polling/voting system for community engagement.

  Features:
  - Create polls with multiple options
  - IP-based duplicate vote prevention
  - Automatic expiration
  - View results with vote counts and percentages
  - Admin moderation
  """

  use GenServer
  require Logger

  @table_name :polls
  @votes_table :poll_votes
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @default_duration_hours 24 * 7  # 1 week default
  @max_options 10
  @max_question_length 200
  @max_option_length 100

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new poll.

  Options:
  - `:duration_hours` - Hours until poll closes (default: 168 = 1 week)
  - `:allow_multiple` - Allow voting for multiple options (default: false)
  """
  def create(question, options, ip, opts \\ []) do
    GenServer.call(__MODULE__, {:create, question, options, ip, opts})
  end

  @doc """
  Gets a poll by ID.
  """
  def get(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc """
  Votes on a poll.
  """
  def vote(poll_id, option_index, ip) do
    GenServer.call(__MODULE__, {:vote, poll_id, option_index, ip})
  end

  @doc """
  Lists active polls.
  """
  def list_active(limit \\ 20) do
    GenServer.call(__MODULE__, {:list_active, limit})
  end

  @doc """
  Lists closed/ended polls.
  """
  def list_closed(limit \\ 20) do
    GenServer.call(__MODULE__, {:list_closed, limit})
  end

  @doc """
  Checks if an IP has voted on a poll.
  """
  def has_voted?(poll_id, ip) do
    GenServer.call(__MODULE__, {:has_voted?, poll_id, ip})
  end

  @doc """
  Closes a poll early (admin only).
  """
  def close(id) do
    GenServer.call(__MODULE__, {:close, id})
  end

  @doc """
  Deletes a poll (admin only).
  """
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @doc """
  Gets poll statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    polls_file = Path.join(data_dir, "polls.dets") |> String.to_charlist()
    votes_file = Path.join(data_dir, "poll_votes.dets") |> String.to_charlist()

    {:ok, _} = :dets.open_file(@table_name, file: polls_file, type: :set)
    {:ok, _} = :dets.open_file(@votes_table, file: votes_file, type: :set)

    Logger.info("[Polls] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, question, options, ip, opts}, _from, state) do
    cond do
      String.length(question) > @max_question_length ->
        {:reply, {:error, :question_too_long}, state}

      String.trim(question) == "" ->
        {:reply, {:error, :empty_question}, state}

      length(options) < 2 ->
        {:reply, {:error, :need_at_least_two_options}, state}

      length(options) > @max_options ->
        {:reply, {:error, :too_many_options}, state}

      Enum.any?(options, &(String.length(&1) > @max_option_length)) ->
        {:reply, {:error, :option_too_long}, state}

      true ->
        id = generate_id()
        now = DateTime.utc_now()
        duration = Keyword.get(opts, :duration_hours, @default_duration_hours)
        ends_at = DateTime.add(now, duration * 3600, :second)

        poll = %{
          id: id,
          question: String.trim(question),
          options: Enum.map(options, &String.trim/1),
          votes: List.duplicate(0, length(options)),
          total_votes: 0,
          created_at: DateTime.to_iso8601(now),
          ends_at: DateTime.to_iso8601(ends_at),
          closed: false,
          allow_multiple: Keyword.get(opts, :allow_multiple, false),
          creator_ip_hash: hash_ip(ip)
        }

        :dets.insert(@table_name, {id, poll})
        :dets.sync(@table_name)

        Logger.info("[Polls] Created poll #{id}: #{question}")
        {:reply, {:ok, id}, state}
    end
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, poll}] ->
        # Check if poll has ended
        poll = maybe_close_expired(poll)
        {:reply, {:ok, poll}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:vote, poll_id, option_index, ip}, _from, state) do
    ip_hash = hash_ip(ip)
    vote_key = {poll_id, ip_hash}

    case :dets.lookup(@table_name, poll_id) do
      [{^poll_id, poll}] ->
        poll = maybe_close_expired(poll)

        cond do
          poll.closed ->
            {:reply, {:error, :poll_closed}, state}

          option_index < 0 or option_index >= length(poll.options) ->
            {:reply, {:error, :invalid_option}, state}

          true ->
            # Check if already voted
            case :dets.lookup(@votes_table, vote_key) do
              [{^vote_key, _}] when not poll.allow_multiple ->
                {:reply, {:error, :already_voted}, state}

              _ ->
                # Record vote
                new_votes = List.update_at(poll.votes, option_index, &(&1 + 1))
                updated_poll = %{poll |
                  votes: new_votes,
                  total_votes: poll.total_votes + 1
                }

                :dets.insert(@table_name, {poll_id, updated_poll})
                :dets.insert(@votes_table, {vote_key, option_index})
                :dets.sync(@table_name)
                :dets.sync(@votes_table)

                Logger.debug("[Polls] Vote on #{poll_id} option #{option_index}")
                {:reply, {:ok, updated_poll}, state}
            end
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_active, limit}, _from, state) do
    now = DateTime.utc_now()

    polls = :dets.foldl(fn {_id, poll}, acc ->
      if not poll.closed do
        case DateTime.from_iso8601(poll.ends_at) do
          {:ok, ends_at, _} ->
            if DateTime.compare(ends_at, now) == :gt, do: [poll | acc], else: acc
          _ -> acc
        end
      else
        acc
      end
    end, [], @table_name)

    active = polls
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, active}, state}
  end

  @impl true
  def handle_call({:list_closed, limit}, _from, state) do
    now = DateTime.utc_now()

    polls = :dets.foldl(fn {_id, poll}, acc ->
      is_ended = poll.closed or case DateTime.from_iso8601(poll.ends_at) do
        {:ok, ends_at, _} -> DateTime.compare(now, ends_at) != :lt
        _ -> false
      end

      if is_ended, do: [poll | acc], else: acc
    end, [], @table_name)

    closed = polls
      |> Enum.sort_by(& &1.ends_at, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, closed}, state}
  end

  @impl true
  def handle_call({:has_voted?, poll_id, ip}, _from, state) do
    ip_hash = hash_ip(ip)
    vote_key = {poll_id, ip_hash}

    result = case :dets.lookup(@votes_table, vote_key) do
      [{^vote_key, _}] -> true
      [] -> false
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:close, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, poll}] ->
        updated = %{poll | closed: true}
        :dets.insert(@table_name, {id, updated})
        :dets.sync(@table_name)
        Logger.info("[Polls] Closed poll #{id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    case :dets.lookup(@table_name, id) do
      [{^id, _}] ->
        :dets.delete(@table_name, id)
        # Also delete all votes for this poll
        :dets.foldl(fn {{pid, _}, _} = entry, acc ->
          if pid == id, do: [:dets.delete(@votes_table, elem(entry, 0)) | acc], else: acc
        end, [], @votes_table)
        :dets.sync(@table_name)
        :dets.sync(@votes_table)
        Logger.info("[Polls] Deleted poll #{id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    now = DateTime.utc_now()

    {total, active, total_votes} =
      :dets.foldl(fn {_id, poll}, {t, a, v} ->
        is_active = not poll.closed and case DateTime.from_iso8601(poll.ends_at) do
          {:ok, ends_at, _} -> DateTime.compare(ends_at, now) == :gt
          _ -> false
        end

        {t + 1, a + (if is_active, do: 1, else: 0), v + poll.total_votes}
      end, {0, 0, 0}, @table_name)

    {:reply, %{
      total_polls: total,
      active_polls: active,
      total_votes: total_votes
    }, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :dets.close(@votes_table)
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

  defp maybe_close_expired(poll) do
    if not poll.closed do
      case DateTime.from_iso8601(poll.ends_at) do
        {:ok, ends_at, _} ->
          if DateTime.compare(DateTime.utc_now(), ends_at) != :lt do
            updated = %{poll | closed: true}
            :dets.insert(@table_name, {poll.id, updated})
            updated
          else
            poll
          end

        _ ->
          poll
      end
    else
      poll
    end
  end
end
