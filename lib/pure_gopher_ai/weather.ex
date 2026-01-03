defmodule PureGopherAi.Weather do
  @moduledoc """
  Weather service using Open-Meteo API.

  Features:
  - Current weather conditions
  - Multi-day forecast
  - AI-enhanced weather descriptions
  - ASCII weather icons
  - No API key required (Open-Meteo is free)
  """

  require Logger

  alias PureGopherAi.AiEngine

  @geocoding_url "https://geocoding-api.open-meteo.com/v1/search"
  @weather_url "https://api.open-meteo.com/v1/forecast"
  @timeout 10_000

  # Weather code to description mapping
  @weather_codes %{
    0 => {"Clear sky", "☀️", "sunny"},
    1 => {"Mainly clear", "🌤️", "partly_cloudy"},
    2 => {"Partly cloudy", "⛅", "partly_cloudy"},
    3 => {"Overcast", "☁️", "cloudy"},
    45 => {"Fog", "🌫️", "foggy"},
    48 => {"Depositing rime fog", "🌫️", "foggy"},
    51 => {"Light drizzle", "🌧️", "rainy"},
    53 => {"Moderate drizzle", "🌧️", "rainy"},
    55 => {"Dense drizzle", "🌧️", "rainy"},
    56 => {"Light freezing drizzle", "🌨️", "snowy"},
    57 => {"Dense freezing drizzle", "🌨️", "snowy"},
    61 => {"Slight rain", "🌧️", "rainy"},
    63 => {"Moderate rain", "🌧️", "rainy"},
    65 => {"Heavy rain", "🌧️", "rainy"},
    66 => {"Light freezing rain", "🌨️", "snowy"},
    67 => {"Heavy freezing rain", "🌨️", "snowy"},
    71 => {"Slight snow fall", "❄️", "snowy"},
    73 => {"Moderate snow fall", "❄️", "snowy"},
    75 => {"Heavy snow fall", "❄️", "snowy"},
    77 => {"Snow grains", "❄️", "snowy"},
    80 => {"Slight rain showers", "🌦️", "rainy"},
    81 => {"Moderate rain showers", "🌦️", "rainy"},
    82 => {"Violent rain showers", "⛈️", "stormy"},
    85 => {"Slight snow showers", "🌨️", "snowy"},
    86 => {"Heavy snow showers", "🌨️", "snowy"},
    95 => {"Thunderstorm", "⛈️", "stormy"},
    96 => {"Thunderstorm with slight hail", "⛈️", "stormy"},
    99 => {"Thunderstorm with heavy hail", "⛈️", "stormy"}
  }

  # ASCII art for weather conditions
  @ascii_weather %{
    "sunny" => """
        \\   /
         .-.
      ― (   ) ―
         `-'
        /   \\
    """,
    "partly_cloudy" => """
       \\  /
     _ /\"\".-.
       \\_(   ).
       /(___(__)
    """,
    "cloudy" => """
         .--.
      .-(    ).
     (___.__)__)
    """,
    "rainy" => """
         .--.
      .-(    ).
     (___.__)__)
      ‚'‚'‚'‚'
    """,
    "snowy" => """
         .--.
      .-(    ).
     (___.__)__)
      * * * *
    """,
    "stormy" => """
         .--.
      .-(    ).
     (___.__)__)
       ⚡ ⚡
    """,
    "foggy" => """
      _ - _ - _
     _ - _ - _ -
      - _ - _ -
     _ - _ - _ -
    """
  }

  @doc """
  Gets the current weather for a location.
  """
  def get_current(location) do
    with {:ok, coords} <- geocode(location),
         {:ok, weather} <- fetch_weather(coords) do
      {:ok, format_current(coords, weather)}
    end
  end

  @doc """
  Gets a multi-day forecast for a location.
  """
  def get_forecast(location, days \\ 5) do
    days = min(days, 7)  # Open-Meteo free tier allows up to 7 days

    with {:ok, coords} <- geocode(location),
         {:ok, weather} <- fetch_weather(coords, days) do
      {:ok, format_forecast(coords, weather, days)}
    end
  end

  @doc """
  Gets AI-enhanced weather description.
  """
  def get_ai_description(location) do
    with {:ok, coords} <- geocode(location),
         {:ok, weather} <- fetch_weather(coords, 3) do
      generate_ai_description(coords, weather)
    end
  end

  @doc """
  Gets ASCII art for a weather code.
  """
  def ascii_art(weather_code) when is_integer(weather_code) do
    case Map.get(@weather_codes, weather_code) do
      {_desc, _emoji, type} -> Map.get(@ascii_weather, type, @ascii_weather["cloudy"])
      nil -> @ascii_weather["cloudy"]
    end
  end

  @doc """
  Gets description for a weather code.
  """
  def weather_description(weather_code) when is_integer(weather_code) do
    case Map.get(@weather_codes, weather_code) do
      {desc, emoji, _type} -> {desc, emoji}
      nil -> {"Unknown", "❓"}
    end
  end

  # Private functions

  defp geocode(location) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    location = String.trim(location)
    encoded_location = URI.encode(location)
    url = "#{@geocoding_url}?name=#{encoded_location}&count=1&language=en&format=json"

    case http_get(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"results" => [result | _]}} ->
            {:ok, %{
              name: result["name"],
              country: result["country"],
              lat: result["latitude"],
              lon: result["longitude"],
              timezone: result["timezone"]
            }}
          {:ok, %{}} ->
            {:error, :location_not_found}
          {:error, _} ->
            {:error, :parse_error}
        end
      {:error, reason} ->
        {:error, {:fetch_error, reason}}
    end
  end

  defp fetch_weather(coords, days \\ 1) do
    params = [
      "latitude=#{coords.lat}",
      "longitude=#{coords.lon}",
      "current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m",
      "daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
      "timezone=#{URI.encode(coords.timezone || "auto")}",
      "forecast_days=#{days}"
    ]

    url = "#{@weather_url}?#{Enum.join(params, "&")}"

    case http_get(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :parse_error}
        end
      {:error, reason} ->
        {:error, {:fetch_error, reason}}
    end
  end

  defp http_get(url) do
    url_charlist = String.to_charlist(url)

    # Extract hostname for SNI and verification
    %URI{host: host} = URI.parse(url)
    host_charlist = String.to_charlist(host)

    http_options = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        server_name_indication: host_charlist,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      timeout: @timeout,
      connect_timeout: 5000
    ]

    options = [body_format: :binary]

    case :httpc.request(:get, {url_charlist, []}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}
      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status}}
      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp format_current(coords, weather) do
    current = weather["current"]
    units = weather["current_units"]

    {desc, emoji} = weather_description(current["weather_code"])
    ascii = ascii_art(current["weather_code"])

    temp = current["temperature_2m"]
    feels_like = current["apparent_temperature"]
    humidity = current["relative_humidity_2m"]
    wind_speed = current["wind_speed_10m"]
    wind_dir = wind_direction_name(current["wind_direction_10m"])

    %{
      location: "#{coords.name}, #{coords.country}",
      description: desc,
      emoji: emoji,
      ascii: ascii,
      temperature: temp,
      temperature_unit: units["temperature_2m"],
      feels_like: feels_like,
      humidity: humidity,
      wind_speed: wind_speed,
      wind_speed_unit: units["wind_speed_10m"],
      wind_direction: wind_dir,
      raw: weather
    }
  end

  defp format_forecast(coords, weather, days) do
    daily = weather["daily"]
    units = weather["daily_units"]

    forecast_days = 0..(days - 1)
      |> Enum.map(fn i ->
        date = Enum.at(daily["time"], i)
        weather_code = Enum.at(daily["weather_code"], i)
        {desc, emoji} = weather_description(weather_code)

        %{
          date: date,
          description: desc,
          emoji: emoji,
          high: Enum.at(daily["temperature_2m_max"], i),
          low: Enum.at(daily["temperature_2m_min"], i),
          precipitation_probability: Enum.at(daily["precipitation_probability_max"], i)
        }
      end)

    %{
      location: "#{coords.name}, #{coords.country}",
      days: forecast_days,
      temperature_unit: units["temperature_2m_max"],
      raw: weather
    }
  end

  defp generate_ai_description(coords, weather) do
    current = weather["current"]
    daily = weather["daily"]

    {desc, _emoji} = weather_description(current["weather_code"])

    forecast_summary = 0..2
      |> Enum.map(fn i ->
        date = Enum.at(daily["time"], i)
        {day_desc, _} = weather_description(Enum.at(daily["weather_code"], i))
        high = Enum.at(daily["temperature_2m_max"], i)
        low = Enum.at(daily["temperature_2m_min"], i)
        "#{date}: #{day_desc}, High: #{high}°C, Low: #{low}°C"
      end)
      |> Enum.join("\n")

    prompt = """
    Write a friendly, conversational weather report for #{coords.name}, #{coords.country}.

    Current conditions:
    - Weather: #{desc}
    - Temperature: #{current["temperature_2m"]}°C (feels like #{current["apparent_temperature"]}°C)
    - Humidity: #{current["relative_humidity_2m"]}%
    - Wind: #{current["wind_speed_10m"]} km/h

    3-day forecast:
    #{forecast_summary}

    Write 2-3 sentences about the current weather and what to expect.
    Include practical advice (e.g., bring an umbrella, wear layers).
    Keep it brief and helpful.
    """

    {:ok, AiEngine.generate(prompt)}
  end

  defp wind_direction_name(degrees) when is_number(degrees) do
    directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                  "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    index = round(degrees / 22.5) |> rem(16)
    Enum.at(directions, index)
  end

  defp wind_direction_name(_), do: "Unknown"
end
