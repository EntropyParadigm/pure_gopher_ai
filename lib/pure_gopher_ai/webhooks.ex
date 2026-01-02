defmodule PureGopherAi.Webhooks do
  @moduledoc """
  Webhook system for notifying external services.

  Features:
  - Register webhooks for various events
  - Retry failed deliveries
  - Webhook signing for verification
  - Delivery logging
  """

  use GenServer
  require Logger

  @table_name :webhooks
  @log_table :webhook_logs
  @data_dir Application.compile_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
  @max_retries 3
  @retry_delays [1_000, 5_000, 30_000]  # 1s, 5s, 30s

  # Event types
  @event_types [
    :new_post,
    :new_comment,
    :new_user,
    :new_follow,
    :new_message,
    :content_reported,
    :user_banned
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new webhook.
  """
  def register(name, url, events, opts \\ []) do
    GenServer.call(__MODULE__, {:register, name, url, events, opts})
  end

  @doc """
  Unregisters a webhook.
  """
  def unregister(webhook_id) do
    GenServer.call(__MODULE__, {:unregister, webhook_id})
  end

  @doc """
  Lists all registered webhooks.
  """
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Gets webhook details.
  """
  def get(webhook_id) do
    GenServer.call(__MODULE__, {:get, webhook_id})
  end

  @doc """
  Triggers an event and notifies all subscribed webhooks.
  """
  def trigger(event_type, payload) do
    GenServer.cast(__MODULE__, {:trigger, event_type, payload})
  end

  @doc """
  Gets delivery logs for a webhook.
  """
  def delivery_logs(webhook_id, opts \\ []) do
    GenServer.call(__MODULE__, {:logs, webhook_id, opts})
  end

  @doc """
  Tests a webhook by sending a test payload.
  """
  def test(webhook_id) do
    GenServer.call(__MODULE__, {:test, webhook_id}, 30_000)
  end

  @doc """
  Returns available event types.
  """
  def event_types, do: @event_types

  # Server callbacks

  @impl true
  def init(_opts) do
    data_dir = Path.expand(@data_dir)
    File.mkdir_p!(data_dir)

    dets_file = Path.join(data_dir, "webhooks.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table_name, file: dets_file, type: :set)

    log_file = Path.join(data_dir, "webhook_logs.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@log_table, file: log_file, type: :bag)

    Logger.info("[Webhooks] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, name, url, events, opts}, _from, state) do
    # Validate URL
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        # Validate events
        valid_events = Enum.filter(events, &(&1 in @event_types))

        if valid_events == [] do
          {:reply, {:error, :no_valid_events}, state}
        else
          webhook_id = generate_id()
          secret = generate_secret()
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          webhook = %{
            id: webhook_id,
            name: sanitize_text(name),
            url: url,
            events: valid_events,
            secret: secret,
            enabled: Keyword.get(opts, :enabled, true),
            created_at: now,
            updated_at: now,
            delivery_count: 0,
            failure_count: 0,
            last_delivery: nil
          }

          :dets.insert(@table_name, {webhook_id, webhook})
          :dets.sync(@table_name)

          Logger.info("[Webhooks] Registered webhook: #{name}")
          {:reply, {:ok, %{id: webhook_id, secret: secret}}, state}
        end

      _ ->
        {:reply, {:error, :invalid_url}, state}
    end
  end

  @impl true
  def handle_call({:unregister, webhook_id}, _from, state) do
    case :dets.lookup(@table_name, webhook_id) do
      [{^webhook_id, webhook}] ->
        :dets.delete(@table_name, webhook_id)
        :dets.sync(@table_name)
        Logger.info("[Webhooks] Unregistered webhook: #{webhook.name}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    webhooks = :dets.foldl(fn {_id, webhook}, acc ->
      [Map.drop(webhook, [:secret]) | acc]
    end, [], @table_name)
    |> Enum.sort_by(& &1.name)

    {:reply, {:ok, webhooks}, state}
  end

  @impl true
  def handle_call({:get, webhook_id}, _from, state) do
    case :dets.lookup(@table_name, webhook_id) do
      [{^webhook_id, webhook}] ->
        {:reply, {:ok, Map.drop(webhook, [:secret])}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:logs, webhook_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)

    logs = :dets.lookup(@log_table, webhook_id)
    |> Enum.map(fn {_id, log} -> log end)
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(limit)

    {:reply, {:ok, logs}, state}
  end

  @impl true
  def handle_call({:test, webhook_id}, _from, state) do
    case :dets.lookup(@table_name, webhook_id) do
      [{^webhook_id, webhook}] ->
        payload = %{
          event: :test,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          data: %{message: "This is a test webhook delivery"}
        }

        result = deliver(webhook, :test, payload)
        {:reply, result, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:trigger, event_type, payload}, state) do
    # Find all webhooks subscribed to this event
    webhooks = :dets.foldl(fn {_id, webhook}, acc ->
      if webhook.enabled and event_type in webhook.events do
        [webhook | acc]
      else
        acc
      end
    end, [], @table_name)

    # Deliver to each webhook asynchronously
    Enum.each(webhooks, fn webhook ->
      spawn(fn ->
        deliver_with_retry(webhook, event_type, payload, 0)
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table_name)
    :dets.close(@log_table)
    :ok
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")
    |> String.trim()
    |> String.slice(0, 100)
  end

  defp sanitize_text(_), do: ""

  defp deliver_with_retry(webhook, event_type, payload, attempt) do
    case deliver(webhook, event_type, payload) do
      {:ok, _} ->
        update_webhook_stats(webhook.id, :success)

      {:error, reason} ->
        if attempt < @max_retries do
          delay = Enum.at(@retry_delays, attempt, 30_000)
          :timer.sleep(delay)
          deliver_with_retry(webhook, event_type, payload, attempt + 1)
        else
          update_webhook_stats(webhook.id, :failure)
          log_delivery(webhook.id, event_type, :failure, reason)
        end
    end
  end

  defp deliver(webhook, event_type, payload) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    body = Jason.encode!(%{
      event: event_type,
      timestamp: now,
      data: payload
    })

    signature = sign_payload(body, webhook.secret)

    headers = [
      {"Content-Type", "application/json"},
      {"X-Webhook-Signature", "sha256=#{signature}"},
      {"X-Webhook-Event", to_string(event_type)},
      {"User-Agent", "PureGopherAI/1.0"}
    ]

    # Using :httpc from Erlang's inets
    request = {String.to_charlist(webhook.url), Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end), ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, 10_000}], []) do
      {:ok, {{_, status_code, _}, _headers, _body}} when status_code >= 200 and status_code < 300 ->
        log_delivery(webhook.id, event_type, :success, status_code)
        {:ok, status_code}

      {:ok, {{_, status_code, _}, _headers, _body}} ->
        log_delivery(webhook.id, event_type, :failure, "HTTP #{status_code}")
        {:error, {:http_error, status_code}}

      {:error, reason} ->
        log_delivery(webhook.id, event_type, :failure, inspect(reason))
        {:error, reason}
    end
  end

  defp sign_payload(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp update_webhook_stats(webhook_id, result) do
    case :dets.lookup(@table_name, webhook_id) do
      [{^webhook_id, webhook}] ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated = case result do
          :success ->
            %{webhook |
              delivery_count: webhook.delivery_count + 1,
              last_delivery: now,
              updated_at: now
            }

          :failure ->
            %{webhook |
              failure_count: webhook.failure_count + 1,
              updated_at: now
            }
        end

        :dets.insert(@table_name, {webhook_id, updated})
        :dets.sync(@table_name)

      [] ->
        :ok
    end
  end

  defp log_delivery(webhook_id, event_type, status, details) do
    log = %{
      event_type: event_type,
      status: status,
      details: details,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :dets.insert(@log_table, {webhook_id, log})
  end
end
