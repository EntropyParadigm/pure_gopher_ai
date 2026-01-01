defmodule PureGopherAi.PromptHelpers do
  @moduledoc """
  Shared helpers for building AI prompts across modules.
  """

  @doc """
  Build instruction text from option atoms.
  """
  def instruction_for(_category, value, mappings) do
    Map.get(mappings, value, Map.get(mappings, :default, ""))
  end

  @doc """
  Build language hint for code-related prompts.
  """
  def language_hint(nil), do: ""
  def language_hint(language), do: "This is #{language} code."

  @doc """
  Parse AI response into trimmed lines.
  """
  def parse_lines(text, opts \\ []) do
    cleaner = Keyword.get(opts, :cleaner, &Function.identity/1)
    limit = Keyword.get(opts, :limit, nil)

    lines = text
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(cleaner)

    if limit, do: Enum.take(lines, limit), else: lines
  end
end
