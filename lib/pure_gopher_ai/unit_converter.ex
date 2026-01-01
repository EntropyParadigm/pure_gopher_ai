defmodule PureGopherAi.UnitConverter do
  @moduledoc """
  Unit converter for common measurements.

  Supports:
  - Length (meters, feet, inches, km, miles, etc.)
  - Weight/Mass (kg, lbs, oz, grams, etc.)
  - Temperature (Celsius, Fahrenheit, Kelvin)
  - Volume (liters, gallons, cups, ml, etc.)
  - Area (sq meters, sq feet, acres, hectares)
  - Speed (km/h, mph, m/s, knots)
  - Data (bytes, KB, MB, GB, TB)
  - Time (seconds, minutes, hours, days)
  """

  # Length conversions (base: meters)
  @length_units %{
    "m" => 1.0,
    "meter" => 1.0,
    "meters" => 1.0,
    "cm" => 0.01,
    "centimeter" => 0.01,
    "centimeters" => 0.01,
    "mm" => 0.001,
    "millimeter" => 0.001,
    "millimeters" => 0.001,
    "km" => 1000.0,
    "kilometer" => 1000.0,
    "kilometers" => 1000.0,
    "in" => 0.0254,
    "inch" => 0.0254,
    "inches" => 0.0254,
    "ft" => 0.3048,
    "foot" => 0.3048,
    "feet" => 0.3048,
    "yd" => 0.9144,
    "yard" => 0.9144,
    "yards" => 0.9144,
    "mi" => 1609.344,
    "mile" => 1609.344,
    "miles" => 1609.344,
    "nmi" => 1852.0,
    "nautical mile" => 1852.0
  }

  # Weight conversions (base: grams)
  @weight_units %{
    "g" => 1.0,
    "gram" => 1.0,
    "grams" => 1.0,
    "kg" => 1000.0,
    "kilogram" => 1000.0,
    "kilograms" => 1000.0,
    "mg" => 0.001,
    "milligram" => 0.001,
    "milligrams" => 0.001,
    "lb" => 453.592,
    "lbs" => 453.592,
    "pound" => 453.592,
    "pounds" => 453.592,
    "oz" => 28.3495,
    "ounce" => 28.3495,
    "ounces" => 28.3495,
    "ton" => 907_185.0,
    "tons" => 907_185.0,
    "tonne" => 1_000_000.0,
    "tonnes" => 1_000_000.0,
    "st" => 6350.29,
    "stone" => 6350.29
  }

  # Volume conversions (base: liters)
  @volume_units %{
    "l" => 1.0,
    "liter" => 1.0,
    "liters" => 1.0,
    "litre" => 1.0,
    "litres" => 1.0,
    "ml" => 0.001,
    "milliliter" => 0.001,
    "milliliters" => 0.001,
    "gal" => 3.78541,
    "gallon" => 3.78541,
    "gallons" => 3.78541,
    "qt" => 0.946353,
    "quart" => 0.946353,
    "quarts" => 0.946353,
    "pt" => 0.473176,
    "pint" => 0.473176,
    "pints" => 0.473176,
    "cup" => 0.236588,
    "cups" => 0.236588,
    "floz" => 0.0295735,
    "fl oz" => 0.0295735,
    "fluid ounce" => 0.0295735,
    "tbsp" => 0.0147868,
    "tablespoon" => 0.0147868,
    "tsp" => 0.00492892,
    "teaspoon" => 0.00492892
  }

  # Area conversions (base: square meters)
  @area_units %{
    "sqm" => 1.0,
    "sq m" => 1.0,
    "square meter" => 1.0,
    "square meters" => 1.0,
    "sqft" => 0.092903,
    "sq ft" => 0.092903,
    "square foot" => 0.092903,
    "square feet" => 0.092903,
    "sqin" => 0.00064516,
    "sq in" => 0.00064516,
    "acre" => 4046.86,
    "acres" => 4046.86,
    "ha" => 10000.0,
    "hectare" => 10000.0,
    "hectares" => 10000.0,
    "sqkm" => 1_000_000.0,
    "sq km" => 1_000_000.0,
    "sqmi" => 2_589_988.11,
    "sq mi" => 2_589_988.11
  }

  # Speed conversions (base: m/s)
  @speed_units %{
    "mps" => 1.0,
    "m/s" => 1.0,
    "kmh" => 0.277778,
    "km/h" => 0.277778,
    "kph" => 0.277778,
    "mph" => 0.44704,
    "knot" => 0.514444,
    "knots" => 0.514444,
    "fps" => 0.3048,
    "ft/s" => 0.3048
  }

  # Data conversions (base: bytes)
  @data_units %{
    "b" => 1.0,
    "byte" => 1.0,
    "bytes" => 1.0,
    "kb" => 1024.0,
    "kilobyte" => 1024.0,
    "kilobytes" => 1024.0,
    "mb" => 1_048_576.0,
    "megabyte" => 1_048_576.0,
    "megabytes" => 1_048_576.0,
    "gb" => 1_073_741_824.0,
    "gigabyte" => 1_073_741_824.0,
    "gigabytes" => 1_073_741_824.0,
    "tb" => 1_099_511_627_776.0,
    "terabyte" => 1_099_511_627_776.0,
    "terabytes" => 1_099_511_627_776.0,
    "pb" => 1_125_899_906_842_624.0,
    "petabyte" => 1_125_899_906_842_624.0
  }

  # Time conversions (base: seconds)
  @time_units %{
    "s" => 1.0,
    "sec" => 1.0,
    "second" => 1.0,
    "seconds" => 1.0,
    "min" => 60.0,
    "minute" => 60.0,
    "minutes" => 60.0,
    "h" => 3600.0,
    "hr" => 3600.0,
    "hour" => 3600.0,
    "hours" => 3600.0,
    "d" => 86400.0,
    "day" => 86400.0,
    "days" => 86400.0,
    "wk" => 604_800.0,
    "week" => 604_800.0,
    "weeks" => 604_800.0,
    "mo" => 2_592_000.0,
    "month" => 2_592_000.0,
    "months" => 2_592_000.0,
    "yr" => 31_536_000.0,
    "year" => 31_536_000.0,
    "years" => 31_536_000.0
  }

  @doc """
  Converts a value from one unit to another.
  Returns {:ok, result, formatted} or {:error, reason}.
  """
  def convert(value, from_unit, to_unit) do
    from_unit = String.downcase(String.trim(from_unit))
    to_unit = String.downcase(String.trim(to_unit))

    cond do
      # Temperature (special case - not linear)
      temperature_unit?(from_unit) and temperature_unit?(to_unit) ->
        convert_temperature(value, from_unit, to_unit)

      # Length
      length_unit?(from_unit) and length_unit?(to_unit) ->
        convert_linear(@length_units, value, from_unit, to_unit)

      # Weight
      weight_unit?(from_unit) and weight_unit?(to_unit) ->
        convert_linear(@weight_units, value, from_unit, to_unit)

      # Volume
      volume_unit?(from_unit) and volume_unit?(to_unit) ->
        convert_linear(@volume_units, value, from_unit, to_unit)

      # Area
      area_unit?(from_unit) and area_unit?(to_unit) ->
        convert_linear(@area_units, value, from_unit, to_unit)

      # Speed
      speed_unit?(from_unit) and speed_unit?(to_unit) ->
        convert_linear(@speed_units, value, from_unit, to_unit)

      # Data
      data_unit?(from_unit) and data_unit?(to_unit) ->
        convert_linear(@data_units, value, from_unit, to_unit)

      # Time
      time_unit?(from_unit) and time_unit?(to_unit) ->
        convert_linear(@time_units, value, from_unit, to_unit)

      # Unknown or incompatible units
      true ->
        {:error, :unknown_units}
    end
  end

  @doc """
  Returns a list of all supported unit categories with examples.
  """
  def categories do
    [
      %{name: "Length", units: ["m", "cm", "mm", "km", "in", "ft", "yd", "mi"]},
      %{name: "Weight", units: ["g", "kg", "mg", "lb", "oz", "ton", "stone"]},
      %{name: "Temperature", units: ["c", "f", "k"]},
      %{name: "Volume", units: ["l", "ml", "gal", "qt", "pt", "cup", "floz"]},
      %{name: "Area", units: ["sqm", "sqft", "acre", "hectare", "sqkm"]},
      %{name: "Speed", units: ["m/s", "km/h", "mph", "knots"]},
      %{name: "Data", units: ["b", "kb", "mb", "gb", "tb"]},
      %{name: "Time", units: ["s", "min", "h", "d", "wk", "mo", "yr"]}
    ]
  end

  @doc """
  Parses a conversion query like "100 km to mi" or "32f to c".
  """
  def parse_query(query) do
    query = String.trim(query)

    # Try various patterns
    patterns = [
      # "100 km to mi" or "100km to mi"
      ~r/^([\d.]+)\s*([a-z\/\s]+?)\s+(?:to|in|as)\s+([a-z\/\s]+)$/i,
      # "100 km -> mi"
      ~r/^([\d.]+)\s*([a-z\/\s]+?)\s*->\s*([a-z\/\s]+)$/i,
      # "100 km = mi"
      ~r/^([\d.]+)\s*([a-z\/\s]+?)\s*=\s*([a-z\/\s]+)$/i
    ]

    result = Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, query) do
        [_, value_str, from_unit, to_unit] ->
          case Float.parse(value_str) do
            {value, _} -> {:ok, value, from_unit, to_unit}
            :error -> nil
          end
        _ -> nil
      end
    end)

    case result do
      {:ok, value, from_unit, to_unit} -> {:ok, value, from_unit, to_unit}
      nil -> {:error, :invalid_format}
    end
  end

  # Private functions

  defp convert_linear(units_map, value, from_unit, to_unit) do
    from_factor = Map.get(units_map, from_unit)
    to_factor = Map.get(units_map, to_unit)

    if from_factor && to_factor do
      # Convert to base unit, then to target unit
      base_value = value * from_factor
      result = base_value / to_factor
      {:ok, result, format_result(value, from_unit, result, to_unit)}
    else
      {:error, :unknown_unit}
    end
  end

  defp convert_temperature(value, from_unit, to_unit) do
    # Normalize unit names
    from = normalize_temp_unit(from_unit)
    to = normalize_temp_unit(to_unit)

    # Convert to Celsius first
    celsius = case from do
      :c -> value
      :f -> (value - 32) * 5 / 9
      :k -> value - 273.15
    end

    # Convert from Celsius to target
    result = case to do
      :c -> celsius
      :f -> celsius * 9 / 5 + 32
      :k -> celsius + 273.15
    end

    {:ok, result, format_result(value, from_unit, result, to_unit)}
  end

  defp normalize_temp_unit(unit) do
    cond do
      unit in ["c", "celsius", "deg c"] -> :c
      unit in ["f", "fahrenheit", "deg f"] -> :f
      unit in ["k", "kelvin"] -> :k
      true -> :unknown
    end
  end

  defp temperature_unit?(unit), do: normalize_temp_unit(unit) != :unknown
  defp length_unit?(unit), do: Map.has_key?(@length_units, unit)
  defp weight_unit?(unit), do: Map.has_key?(@weight_units, unit)
  defp volume_unit?(unit), do: Map.has_key?(@volume_units, unit)
  defp area_unit?(unit), do: Map.has_key?(@area_units, unit)
  defp speed_unit?(unit), do: Map.has_key?(@speed_units, unit)
  defp data_unit?(unit), do: Map.has_key?(@data_units, unit)
  defp time_unit?(unit), do: Map.has_key?(@time_units, unit)

  defp format_result(from_value, from_unit, to_value, to_unit) do
    from_str = format_number(from_value)
    to_str = format_number(to_value)
    "#{from_str} #{from_unit} = #{to_str} #{to_unit}"
  end

  defp format_number(num) when is_float(num) do
    cond do
      num == Float.round(num, 0) -> :erlang.float_to_binary(num, decimals: 0)
      abs(num) >= 1000 -> :erlang.float_to_binary(num, decimals: 2)
      abs(num) >= 1 -> :erlang.float_to_binary(num, decimals: 4)
      abs(num) >= 0.01 -> :erlang.float_to_binary(num, decimals: 6)
      true -> :erlang.float_to_binary(num, decimals: 10)
    end
  end

  defp format_number(num), do: to_string(num)
end
