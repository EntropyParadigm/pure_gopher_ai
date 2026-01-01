defmodule PureGopherAi.Reactions do
  @moduledoc """
  Reactions/voting system for content.

  Features:
  - Upvote/downvote on phlog posts, bulletin threads, guestbook entries
  - One vote per user per item
  - Change or remove votes
  - Aggregate vote counts
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserProfiles

  @table_name :reactions
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")

  # Content types that can be voted on
  @content_types [:phlog, :bulletin, :guestbook, :comment]

  # Reaction types
  @reaction_types [:upvote, :downvote]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds or updates a reaction on content.
  Returns {:ok, new_score} or {:error, reason}.
  """
  def react(username, passphrase, content_type, content_id, reaction) do
    GenServer.call(__MODULE__, {:react, username, passphrase, content_type, content_id, reaction})
  end

  @doc """
  Removes a reaction from content.
  """
  def unreact(username, passphrase, content_type, content_id) do
    GenServer.call(__MODULE__, {:unreact, username, passphrase, content_type, content_id})
  end

  @doc """
  Gets the current reaction score for content.
  Returns %{upvotes: n, downvotes: n, score: n}
  """
  def get_score(content_type, content_id) do
    GenServer.call(__MODULE__, {:get_score, content_type, content_id})
  end

  @doc """
  Gets the current user's reaction on content.
  Returns :upvote, :downvote, or nil
  """
  def get_user_reaction(username, content_type, content_id) do
    GenServer.call(__MODULE__, {:get_user_reaction, username, content_type, content_id})
  end

  @doc """
  Gets top-voted content of a type.
  """
  def top_content(content_type, opts \\ []) do
    GenServer.call(__MODULE__, {:top_content, content_type, opts})
  end

  @doc """
  Gets all reactions by a user.
  """
  def user_reactions(username, opts \\ []) do
    GenServer.call(__MODULE__, {:user_reactions, username, opts})
  end

  @doc """
  Returns valid content types.
  """
  def content_types, do: @content_types

  @doc """
  Returns valid reaction types.
  """
  def reaction_types, do: @reaction_types

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "reactions.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # ETS for aggregated scores (cache)
    :ets.new(:reaction_scores, [:named_table, :public, :set])

    Logger.info("[Reactions] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:react, username, passphrase, content_type, content_id, reaction}, _from, state) do
    # Validate inputs
    cond do
      content_type not in @content_types ->
        {:reply, {:error, :invalid_content_type}, state}

      reaction not in @reaction_types ->
        {:reply, {:error, :invalid_reaction}, state}

      true ->
        # Authenticate user
        case UserProfiles.authenticate(username, passphrase) do
          {:ok, _profile} ->
            username_lower = String.downcase(String.trim(username))
            key = {username_lower, content_type, content_id}

            # Check for existing reaction
            old_reaction = case :dets.lookup(@table_name, key) do
              [{^key, data}] -> data.reaction
              [] -> nil
            end

            now = DateTime.utc_now() |> DateTime.to_iso8601()

            reaction_data = %{
              username: username,
              username_lower: username_lower,
              content_type: content_type,
              content_id: content_id,
              reaction: reaction,
              created_at: now,
              updated_at: now
            }

            :dets.insert(@table_name, {key, reaction_data})
            :dets.sync(@table_name)

            # Update cached score
            update_score_cache(content_type, content_id, old_reaction, reaction)

            score = get_score_internal(content_type, content_id)
            Logger.debug("[Reactions] #{username} #{reaction} on #{content_type}/#{content_id}")
            {:reply, {:ok, score}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:unreact, username, passphrase, content_type, content_id}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(String.trim(username))
        key = {username_lower, content_type, content_id}

        # Get existing reaction for score update
        old_reaction = case :dets.lookup(@table_name, key) do
          [{^key, data}] -> data.reaction
          [] -> nil
        end

        if old_reaction do
          :dets.delete(@table_name, key)
          :dets.sync(@table_name)

          # Update cached score
          update_score_cache(content_type, content_id, old_reaction, nil)

          score = get_score_internal(content_type, content_id)
          {:reply, {:ok, score}, state}
        else
          {:reply, {:error, :no_reaction}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_score, content_type, content_id}, _from, state) do
    score = get_score_internal(content_type, content_id)
    {:reply, score, state}
  end

  @impl true
  def handle_call({:get_user_reaction, username, content_type, content_id}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    key = {username_lower, content_type, content_id}

    reaction = case :dets.lookup(@table_name, key) do
      [{^key, data}] -> data.reaction
      [] -> nil
    end

    {:reply, reaction, state}
  end

  @impl true
  def handle_call({:top_content, content_type, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    min_score = Keyword.get(opts, :min_score, 1)

    # Aggregate scores by content_id
    scores = :dets.foldl(fn {_key, data}, acc ->
      if data.content_type == content_type do
        score_change = if data.reaction == :upvote, do: 1, else: -1
        Map.update(acc, data.content_id, score_change, &(&1 + score_change))
      else
        acc
      end
    end, %{}, @table_name)

    top = scores
      |> Enum.filter(fn {_id, score} -> score >= min_score end)
      |> Enum.sort_by(fn {_id, score} -> -score end)
      |> Enum.take(limit)
      |> Enum.map(fn {id, score} -> %{content_id: id, score: score} end)

    {:reply, {:ok, top}, state}
  end

  @impl true
  def handle_call({:user_reactions, username, opts}, _from, state) do
    username_lower = String.downcase(String.trim(username))
    limit = Keyword.get(opts, :limit, 50)
    content_type = Keyword.get(opts, :type)

    reactions = :dets.foldl(fn {{user, ctype, cid}, data}, acc ->
      if user == username_lower and (is_nil(content_type) or ctype == content_type) do
        [%{
          content_type: ctype,
          content_id: cid,
          reaction: data.reaction,
          created_at: data.created_at
        } | acc]
      else
        acc
      end
    end, [], @table_name)
    |> Enum.sort_by(& &1.created_at, :desc)
    |> Enum.take(limit)

    {:reply, {:ok, reactions}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp get_score_internal(content_type, content_id) do
    cache_key = {content_type, content_id}

    case :ets.lookup(:reaction_scores, cache_key) do
      [{^cache_key, score_data}] ->
        score_data

      [] ->
        # Calculate from DETS
        {upvotes, downvotes} = :dets.foldl(fn {_key, data}, {up, down} ->
          if data.content_type == content_type and data.content_id == content_id do
            case data.reaction do
              :upvote -> {up + 1, down}
              :downvote -> {up, down + 1}
            end
          else
            {up, down}
          end
        end, {0, 0}, @table_name)

        score_data = %{upvotes: upvotes, downvotes: downvotes, score: upvotes - downvotes}
        :ets.insert(:reaction_scores, {cache_key, score_data})
        score_data
    end
  end

  defp update_score_cache(content_type, content_id, old_reaction, new_reaction) do
    cache_key = {content_type, content_id}

    current = case :ets.lookup(:reaction_scores, cache_key) do
      [{^cache_key, data}] -> data
      [] -> %{upvotes: 0, downvotes: 0, score: 0}
    end

    # Remove old reaction
    adjusted = case old_reaction do
      :upvote -> %{current | upvotes: max(0, current.upvotes - 1)}
      :downvote -> %{current | downvotes: max(0, current.downvotes - 1)}
      nil -> current
    end

    # Add new reaction
    final = case new_reaction do
      :upvote -> %{adjusted | upvotes: adjusted.upvotes + 1}
      :downvote -> %{adjusted | downvotes: adjusted.downvotes + 1}
      nil -> adjusted
    end

    final = %{final | score: final.upvotes - final.downvotes}
    :ets.insert(:reaction_scores, {cache_key, final})
  end
end
