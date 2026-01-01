defmodule PureGopherAi.Mailbox do
  @moduledoc """
  Internal messaging system for registered users.

  Features:
  - Send private messages between users
  - Passphrase authentication required for sending
  - AI content moderation
  - Inbox with unread count
  - Message threading
  - Rate limiting
  - Message expiration
  """

  use GenServer
  require Logger

  alias PureGopherAi.UserProfiles
  alias PureGopherAi.ContentModerator
  alias PureGopherAi.InputSanitizer

  @table_name :mailbox
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_subject_length 100
  @max_message_length 2000
  @max_messages_per_user 100
  @cooldown_ms 60_000  # 1 minute between messages
  @message_ttl_days 30

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends a message from one user to another.
  Requires passphrase authentication for the sender.
  """
  def send_message(from_username, passphrase, to_username, subject, body, ip \\ nil) do
    GenServer.call(__MODULE__, {:send, from_username, passphrase, to_username, subject, body, ip}, 30_000)
  end

  @doc """
  Gets inbox for a user. Requires passphrase authentication.
  """
  def get_inbox(username, passphrase, opts \\ []) do
    GenServer.call(__MODULE__, {:inbox, username, passphrase, opts})
  end

  @doc """
  Gets sent messages for a user. Requires passphrase authentication.
  """
  def get_sent(username, passphrase, opts \\ []) do
    GenServer.call(__MODULE__, {:sent, username, passphrase, opts})
  end

  @doc """
  Reads a specific message. Requires passphrase authentication.
  """
  def read_message(username, passphrase, message_id) do
    GenServer.call(__MODULE__, {:read, username, passphrase, message_id})
  end

  @doc """
  Deletes a message. Requires passphrase authentication.
  """
  def delete_message(username, passphrase, message_id) do
    GenServer.call(__MODULE__, {:delete, username, passphrase, message_id})
  end

  @doc """
  Gets unread count for a user. Requires passphrase authentication.
  """
  def unread_count(username, passphrase) do
    GenServer.call(__MODULE__, {:unread_count, username, passphrase})
  end

  @doc """
  Marks a message as read. Requires passphrase authentication.
  """
  def mark_read(username, passphrase, message_id) do
    GenServer.call(__MODULE__, {:mark_read, username, passphrase, message_id})
  end

  @doc """
  Gets mailbox statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "mailbox.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    # Track cooldowns in ETS
    :ets.new(:mailbox_cooldowns, [:named_table, :public, :set])

    # Schedule cleanup
    schedule_cleanup()

    Logger.info("[Mailbox] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:send, from_username, passphrase, to_username, subject, body, ip}, _from, state) do
    # Sanitize inputs first
    from_username_clean = sanitize_username(from_username)
    to_username_clean = sanitize_username(to_username)
    subject_clean = sanitize_text(subject)
    body_clean = sanitize_text(body)

    # Authenticate sender
    case UserProfiles.authenticate(from_username, passphrase, ip) do
      {:ok, _profile} ->
        ip_hash = hash_ip(ip)
        now = System.system_time(:millisecond)

        cond do
          # Rate limit check
          check_cooldown(ip_hash, now) == :rate_limited ->
            {:reply, {:error, :rate_limited}, state}

          # Validate sender
          from_username_clean == "" ->
            {:reply, {:error, :invalid_sender}, state}

          # Validate recipient
          to_username_clean == "" ->
            {:reply, {:error, :invalid_recipient}, state}

          # Can't message yourself
          String.downcase(from_username_clean) == String.downcase(to_username_clean) ->
            {:reply, {:error, :cannot_message_self}, state}

          # Validate subject
          subject_clean == "" ->
            {:reply, {:error, :empty_subject}, state}

          String.length(subject_clean) > @max_subject_length ->
            {:reply, {:error, :subject_too_long}, state}

          # Validate body
          body_clean == "" ->
            {:reply, {:error, :empty_message}, state}

          String.length(body_clean) > @max_message_length ->
            {:reply, {:error, :message_too_long}, state}

          # Check recipient exists
          not recipient_exists?(to_username_clean) ->
            {:reply, {:error, :recipient_not_found}, state}

          # Check inbox limit
          inbox_full?(to_username_clean) ->
            {:reply, {:error, :recipient_inbox_full}, state}

          true ->
            # Content moderation
            case ContentModerator.moderate(subject_clean <> "\n\n" <> body_clean, :message) do
              {:ok, :approved} ->
                message_id = generate_id()

                message = %{
                  id: message_id,
                  from: from_username_clean,
                  to: to_username_clean,
                  subject: subject_clean,
                  body: body_clean,
                  read: false,
                  created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
                  ip_hash: ip_hash
                }

                # Store message for recipient (inbox)
                inbox_key = {:inbox, String.downcase(to_username_clean), message_id}
                :dets.insert(@table_name, {inbox_key, message})

                # Store message for sender (sent)
                sent_key = {:sent, String.downcase(from_username_clean), message_id}
                :dets.insert(@table_name, {sent_key, message})

                :dets.sync(@table_name)

                # Update cooldown
                :ets.insert(:mailbox_cooldowns, {ip_hash, now})

                Logger.info("[Mailbox] Message sent: #{from_username_clean} -> #{to_username_clean}")
                {:reply, {:ok, message_id}, state}

              {:error, :blocked, reason} ->
                {:reply, {:error, :content_blocked, reason}, state}
            end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:inbox, username, passphrase, opts}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(sanitize_username(username))
        limit = Keyword.get(opts, :limit, 20)
        offset = Keyword.get(opts, :offset, 0)

        messages = :dets.foldl(fn
          {{:inbox, ^username_lower, _id}, msg}, acc -> [msg | acc]
          _, acc -> acc
        end, [], @table_name)

        sorted = messages
          |> Enum.sort_by(& &1.created_at, :desc)
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.map(&Map.drop(&1, [:ip_hash]))

        {:reply, {:ok, sorted}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:sent, username, passphrase, opts}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(sanitize_username(username))
        limit = Keyword.get(opts, :limit, 20)
        offset = Keyword.get(opts, :offset, 0)

        messages = :dets.foldl(fn
          {{:sent, ^username_lower, _id}, msg}, acc -> [msg | acc]
          _, acc -> acc
        end, [], @table_name)

        sorted = messages
          |> Enum.sort_by(& &1.created_at, :desc)
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.map(&Map.drop(&1, [:ip_hash]))

        {:reply, {:ok, sorted}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read, username, passphrase, message_id}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(sanitize_username(username))
        inbox_key = {:inbox, username_lower, message_id}

        case :dets.lookup(@table_name, inbox_key) do
          [{^inbox_key, message}] ->
            # Mark as read
            updated = %{message | read: true}
            :dets.insert(@table_name, {inbox_key, updated})
            :dets.sync(@table_name)

            {:reply, {:ok, Map.drop(updated, [:ip_hash])}, state}

          [] ->
            # Check sent folder
            sent_key = {:sent, username_lower, message_id}
            case :dets.lookup(@table_name, sent_key) do
              [{^sent_key, message}] ->
                {:reply, {:ok, Map.drop(message, [:ip_hash])}, state}
              [] ->
                {:reply, {:error, :not_found}, state}
            end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete, username, passphrase, message_id}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(sanitize_username(username))

        # Try to delete from inbox
        inbox_key = {:inbox, username_lower, message_id}
        inbox_deleted = case :dets.lookup(@table_name, inbox_key) do
          [{^inbox_key, _}] ->
            :dets.delete(@table_name, inbox_key)
            true
          [] ->
            false
        end

        # Try to delete from sent
        sent_key = {:sent, username_lower, message_id}
        sent_deleted = case :dets.lookup(@table_name, sent_key) do
          [{^sent_key, _}] ->
            :dets.delete(@table_name, sent_key)
            true
          [] ->
            false
        end

        if inbox_deleted or sent_deleted do
          :dets.sync(@table_name)
          Logger.info("[Mailbox] Message deleted: #{message_id} by #{username_lower}")
          {:reply, :ok, state}
        else
          {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unread_count, username, passphrase}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(sanitize_username(username))

        count = :dets.foldl(fn
          {{:inbox, ^username_lower, _id}, %{read: false}}, acc -> acc + 1
          _, acc -> acc
        end, 0, @table_name)

        {:reply, {:ok, count}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:mark_read, username, passphrase, message_id}, _from, state) do
    case UserProfiles.authenticate(username, passphrase) do
      {:ok, _profile} ->
        username_lower = String.downcase(sanitize_username(username))
        inbox_key = {:inbox, username_lower, message_id}

        case :dets.lookup(@table_name, inbox_key) do
          [{^inbox_key, message}] ->
            updated = %{message | read: true}
            :dets.insert(@table_name, {inbox_key, updated})
            :dets.sync(@table_name)
            {:reply, :ok, state}

          [] ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {total_messages, total_unread} = :dets.foldl(fn
      {{:inbox, _, _}, %{read: false}}, {t, u} -> {t + 1, u + 1}
      {{:inbox, _, _}, _}, {t, u} -> {t + 1, u}
      _, acc -> acc
    end, {0, 0}, @table_name)

    {:reply, %{
      total_messages: total_messages,
      total_unread: total_unread
    }, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
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
    case :ets.lookup(:mailbox_cooldowns, ip_hash) do
      [{^ip_hash, last_send}] when now - last_send < @cooldown_ms ->
        :rate_limited
      _ ->
        :ok
    end
  end

  defp sanitize_username(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.replace(~r/[^\w]/, "")
    |> String.slice(0, 20)
  end

  defp sanitize_username(_), do: ""

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")  # Strip HTML
    |> then(&InputSanitizer.sanitize(&1, allow_newlines: true))
  end

  defp sanitize_text(_), do: ""

  defp recipient_exists?(username) do
    # Check if user has a profile
    case Code.ensure_loaded(PureGopherAi.UserProfiles) do
      {:module, _} ->
        case PureGopherAi.UserProfiles.get(username) do
          {:ok, _} -> true
          _ -> false
        end
      _ ->
        # If UserProfiles not available, allow any username
        true
    end
  end

  defp inbox_full?(username) do
    username = String.downcase(username)

    count = :dets.foldl(fn
      {{:inbox, ^username, _id}, _}, acc -> acc + 1
      _, acc -> acc
    end, 0, @table_name)

    count >= @max_messages_per_user
  end

  defp schedule_cleanup do
    # Run cleanup every hour
    Process.send_after(self(), :cleanup, 3_600_000)
  end

  defp cleanup_expired do
    cutoff = DateTime.utc_now()
      |> DateTime.add(-@message_ttl_days * 24 * 60 * 60, :second)
      |> DateTime.to_iso8601()

    expired = :dets.foldl(fn
      {key, %{created_at: created_at}}, acc when created_at < cutoff ->
        [key | acc]
      _, acc ->
        acc
    end, [], @table_name)

    Enum.each(expired, fn key ->
      :dets.delete(@table_name, key)
    end)

    if length(expired) > 0 do
      :dets.sync(@table_name)
      Logger.info("[Mailbox] Cleaned up #{length(expired)} expired messages")
    end
  end
end
