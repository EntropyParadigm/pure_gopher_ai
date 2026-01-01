defmodule PureGopherAi.GopherPlus do
  @moduledoc """
  Gopher+ protocol support for extended metadata.

  Gopher+ extends the basic Gopher protocol with:
  - Item attributes (size, date, admin, views)
  - Alternative views (different formats)
  - ASK forms (structured input)
  - Abstract/summary text

  Reference: gopher://gopher.floodgap.com/0/gopher/gp/gplus
  """

  require Logger

  # Gopher+ attribute blocks
  @info_block "+INFO"
  @admin_block "+ADMIN"
  @views_block "+VIEWS"
  @abstract_block "+ABSTRACT"
  @ask_block "+ASK"

  @doc """
  Checks if a request is a Gopher+ request.
  Gopher+ requests end with \t+ or \t$ or \t!
  """
  def gopher_plus_request?(selector) do
    String.ends_with?(selector, "\t+") or
    String.ends_with?(selector, "\t$") or
    String.ends_with?(selector, "\t!")
  end

  @doc """
  Parses a Gopher+ selector to extract the base selector and request type.
  Returns {base_selector, type} where type is :attributes, :info_only, or :data
  """
  def parse_selector(selector) do
    cond do
      String.ends_with?(selector, "\t$") ->
        {String.trim_trailing(selector, "\t$"), :info_only}

      String.ends_with?(selector, "\t!") ->
        {String.trim_trailing(selector, "\t!"), :data}

      String.ends_with?(selector, "\t+") ->
        {String.trim_trailing(selector, "\t+"), :attributes}

      true ->
        {selector, :standard}
    end
  end

  @doc """
  Generates Gopher+ attribute response for an item.
  """
  def generate_attributes(item_info) do
    info = generate_info_block(item_info)
    admin = generate_admin_block(item_info)
    views = generate_views_block(item_info)
    abstract = generate_abstract_block(item_info)

    # Gopher+ response starts with +- followed by byte count
    content = [info, admin, views, abstract]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\r\n")

    byte_count = byte_size(content)

    "+-#{byte_count}\r\n#{content}"
  end

  @doc """
  Generates a Gopher+ directory listing with attributes.
  """
  def generate_directory_plus(items, host, port) do
    items
    |> Enum.map(fn item ->
      line = format_gophermap_line(item, host, port)
      attrs = generate_item_attributes(item)
      "#{line}\r\n#{attrs}"
    end)
    |> Enum.join("\r\n")
    |> then(fn content -> "#{content}\r\n.\r\n" end)
  end

  @doc """
  Generates +INFO block.
  """
  def generate_info_block(item) do
    type = Map.get(item, :type, "0")
    title = Map.get(item, :title, "")
    selector = Map.get(item, :selector, "")
    host = Map.get(item, :host, "localhost")
    port = Map.get(item, :port, 70)

    """
    #{@info_block}: #{type}#{title}\t#{selector}\t#{host}\t#{port}
    """
    |> String.trim()
  end

  @doc """
  Generates +ADMIN block.
  """
  def generate_admin_block(item) do
    admin = Map.get(item, :admin)
    mod_date = Map.get(item, :modified_at) || Map.get(item, :created_at)

    if admin || mod_date do
      parts = []

      parts = if admin do
        [" Admin: #{admin}" | parts]
      else
        parts
      end

      parts = if mod_date do
        formatted = format_gopher_date(mod_date)
        [" Mod-Date: #{formatted}" | parts]
      else
        parts
      end

      "#{@admin_block}:\r\n#{Enum.join(Enum.reverse(parts), "\r\n")}"
    else
      nil
    end
  end

  @doc """
  Generates +VIEWS block for alternative representations.
  """
  def generate_views_block(item) do
    views = Map.get(item, :views, [])

    if views != [] do
      view_lines = Enum.map(views, fn view ->
        mime = Map.get(view, :mime, "text/plain")
        lang = Map.get(view, :language, "en")
        size = Map.get(view, :size)

        size_str = if size, do: " #{size}", else: ""
        " #{mime} #{lang}:#{size_str}"
      end)

      "#{@views_block}:\r\n#{Enum.join(view_lines, "\r\n")}"
    else
      nil
    end
  end

  @doc """
  Generates +ABSTRACT block (summary text).
  """
  def generate_abstract_block(item) do
    abstract = Map.get(item, :abstract) || Map.get(item, :summary)

    if abstract do
      # Abstract lines must start with a space
      lines = abstract
        |> String.split("\n")
        |> Enum.map(&(" " <> &1))
        |> Enum.join("\r\n")

      "#{@abstract_block}:\r\n#{lines}"
    else
      nil
    end
  end

  @doc """
  Generates +ASK block for forms.
  """
  def generate_ask_block(fields) do
    field_lines = Enum.map(fields, fn field ->
      type = Map.get(field, :type, :ask)
      prompt = Map.get(field, :prompt, "")
      default = Map.get(field, :default, "")

      case type do
        :ask -> "Ask: #{prompt}\t#{default}"
        :choose -> "Choose: #{prompt}\t#{Enum.join(field.options, "\t")}"
        :select -> "Select: #{prompt}\t#{Enum.join(field.options, "\t")}"
        :choosef -> "ChooseF: #{prompt}"
        _ -> "Ask: #{prompt}"
      end
    end)

    "#{@ask_block}:\r\n#{Enum.join(field_lines, "\r\n")}"
  end

  @doc """
  Parses ASK form response from client.
  """
  def parse_ask_response(data) do
    data
    |> String.split("\t")
    |> Enum.map(&String.trim/1)
  end

  @doc """
  Generates item attributes inline (for directory listings).
  """
  def generate_item_attributes(item) do
    size = Map.get(item, :size)
    created = Map.get(item, :created_at)
    views = Map.get(item, :view_count, 0)

    attrs = []

    attrs = if size do
      ["Size=#{size}" | attrs]
    else
      attrs
    end

    attrs = if created do
      ["Date=#{format_gopher_date(created)}" | attrs]
    else
      attrs
    end

    attrs = if views > 0 do
      ["Views=#{views}" | attrs]
    else
      attrs
    end

    if attrs != [] do
      " [#{Enum.join(Enum.reverse(attrs), ", ")}]"
    else
      ""
    end
  end

  @doc """
  Formats a standard gophermap line.
  """
  def format_gophermap_line(item, host, port) do
    type = Map.get(item, :type, "i")
    title = Map.get(item, :title, "")
    selector = Map.get(item, :selector, "")
    item_host = Map.get(item, :host, host)
    item_port = Map.get(item, :port, port)

    "#{type}#{title}\t#{selector}\t#{item_host}\t#{item_port}"
  end

  @doc """
  Builds a Gopher+ response with data and attributes.
  """
  def build_response(data, item_info, opts \\ []) do
    include_attrs = Keyword.get(opts, :include_attrs, true)

    if include_attrs do
      attrs = generate_attributes(item_info)
      data_size = byte_size(data)

      # Format: +-1 (continue reading), then attributes, then data
      "+-1\r\n#{attrs}\r\n+#{data_size}\r\n#{data}"
    else
      data
    end
  end

  # Private functions

  defp format_gopher_date(date_string) when is_binary(date_string) do
    # Convert ISO8601 to Gopher+ date format: YYYYMMDDHHMMSS
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%Y%m%d%H%M%S")

      _ ->
        # Try just date
        case Date.from_iso8601(date_string) do
          {:ok, d} -> "#{Date.to_iso8601(d) |> String.replace("-", "")}000000"
          _ -> ""
        end
    end
  end

  defp format_gopher_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y%m%d%H%M%S")
  end

  defp format_gopher_date(_), do: ""
end
