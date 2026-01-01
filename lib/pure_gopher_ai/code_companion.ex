defmodule PureGopherAi.CodeCompanion do
  @moduledoc """
  AI-powered code companion for explanation, review, and assistance.

  Features:
  - Explain what code does (any language)
  - Basic code review with suggestions
  - Pseudocode to real code conversion
  - Regex builder from natural language
  - SQL query generation
  - Algorithm explanation
  """

  alias PureGopherAi.AiEngine

  @languages [:python, :javascript, :elixir, :rust, :go, :java, :c, :cpp, :ruby, :sql]
  @algorithms [:sorting, :searching, :graph, :dynamic_programming, :recursion, :trees, :hashing]

  @doc """
  Returns supported programming languages.
  """
  def languages, do: @languages

  @doc """
  Returns algorithm categories.
  """
  def algorithms, do: @algorithms

  @doc """
  Explain what a piece of code does.
  """
  def explain(code, opts \\ []) do
    language = Keyword.get(opts, :language, nil)
    detail = Keyword.get(opts, :detail, :normal)

    language_hint = if language do
      "This code is written in #{language}."
    else
      "Detect the programming language from the code."
    end

    detail_instruction = case detail do
      :brief -> "Give a brief 2-3 sentence explanation."
      :normal -> "Explain at a moderate level of detail."
      :detailed -> "Provide a detailed line-by-line explanation."
      _ -> "Explain at a moderate level of detail."
    end

    prompt = """
    You are a programming tutor. Explain what this code does.

    #{language_hint}
    #{detail_instruction}

    Code:
    ```
    #{code}
    ```

    Explain:
    1. What the code does overall
    2. Key operations or algorithms used
    3. Input/output behavior

    Write the explanation clearly for someone learning to code.
    """

    case AiEngine.generate(prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Review code and suggest improvements.
  """
  def review(code, opts \\ []) do
    language = Keyword.get(opts, :language, nil)
    focus = Keyword.get(opts, :focus, :all)

    language_hint = if language do
      "This is #{language} code."
    else
      ""
    end

    focus_instruction = case focus do
      :bugs -> "Focus on potential bugs and errors."
      :performance -> "Focus on performance optimizations."
      :style -> "Focus on code style and readability."
      :security -> "Focus on security vulnerabilities."
      :all -> "Review for bugs, performance, style, and best practices."
      _ -> "Review for bugs, performance, style, and best practices."
    end

    prompt = """
    You are a senior code reviewer. Review this code and suggest improvements.

    #{language_hint}
    #{focus_instruction}

    Code:
    ```
    #{code}
    ```

    Provide:
    1. Summary of what the code does
    2. Issues found (if any)
    3. Specific suggestions for improvement
    4. Good practices already in use (if any)

    Be constructive and educational in your feedback.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Convert pseudocode to real code.
  """
  def pseudocode_to_code(pseudocode, target_language \\ :python) do
    prompt = """
    You are a skilled programmer. Convert this pseudocode to #{target_language}.

    Pseudocode:
    ```
    #{pseudocode}
    ```

    Requirements:
    - Write clean, idiomatic #{target_language} code
    - Include comments explaining key parts
    - Handle edge cases appropriately
    - Follow #{target_language} best practices

    Write only the code, no additional explanation.
    """

    case AiEngine.generate(prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Build a regex pattern from natural language description.
  """
  def build_regex(description, opts \\ []) do
    flavor = Keyword.get(opts, :flavor, :pcre)

    flavor_note = case flavor do
      :pcre -> "Use PCRE/Perl-compatible regex syntax."
      :javascript -> "Use JavaScript regex syntax."
      :python -> "Use Python regex syntax."
      :posix -> "Use POSIX Basic Regular Expression syntax."
      _ -> "Use PCRE/Perl-compatible regex syntax."
    end

    prompt = """
    You are a regex expert. Create a regular expression based on this description:

    Description: #{description}

    #{flavor_note}

    Provide:
    1. The regex pattern
    2. Explanation of each part
    3. Example strings that would match
    4. Example strings that would NOT match

    Format your response clearly with the pattern first.
    """

    case AiEngine.generate(prompt, max_new_tokens: 400) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Generate SQL query from natural language.
  """
  def generate_sql(description, opts \\ []) do
    dialect = Keyword.get(opts, :dialect, :standard)
    tables = Keyword.get(opts, :tables, nil)

    dialect_note = case dialect do
      :mysql -> "Use MySQL syntax."
      :postgresql -> "Use PostgreSQL syntax."
      :sqlite -> "Use SQLite syntax."
      :mssql -> "Use Microsoft SQL Server syntax."
      :standard -> "Use standard SQL syntax."
      _ -> "Use standard SQL syntax."
    end

    tables_info = if tables do
      "Available tables: #{tables}"
    else
      "Infer reasonable table and column names from the request."
    end

    prompt = """
    You are a SQL expert. Generate a SQL query based on this request:

    Request: #{description}

    #{dialect_note}
    #{tables_info}

    Provide:
    1. The SQL query
    2. Brief explanation of what it does
    3. Any assumptions made about the table structure

    Write clean, readable SQL with proper formatting.
    """

    case AiEngine.generate(prompt, max_new_tokens: 500) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Explain an algorithm.
  """
  def explain_algorithm(algorithm, opts \\ []) do
    language = Keyword.get(opts, :language, :python)
    include_code = Keyword.get(opts, :include_code, true)

    code_instruction = if include_code do
      "Include a #{language} implementation."
    else
      "Focus on the concept, no code needed."
    end

    prompt = """
    You are a computer science professor. Explain the #{algorithm} algorithm.

    #{code_instruction}

    Include:
    1. What the algorithm does
    2. How it works (step by step)
    3. Time and space complexity (Big O)
    4. When to use it
    5. Advantages and disadvantages
    #{if include_code, do: "6. Working code example", else: ""}

    Explain clearly for someone learning data structures and algorithms.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Debug code and suggest fixes.
  """
  def debug(code, error_message \\ nil, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    language_hint = if language do
      "This is #{language} code."
    else
      ""
    end

    error_info = if error_message do
      "Error message: #{error_message}"
    else
      "No specific error message provided. Look for potential issues."
    end

    prompt = """
    You are a debugging expert. Help fix this code.

    #{language_hint}
    #{error_info}

    Code:
    ```
    #{code}
    ```

    Provide:
    1. Identified bug(s) or issue(s)
    2. Explanation of why it's a problem
    3. The corrected code
    4. How to prevent this issue in the future

    Be specific about line numbers and exact fixes needed.
    """

    case AiEngine.generate(prompt, max_new_tokens: 700) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Refactor code for better quality.
  """
  def refactor(code, opts \\ []) do
    language = Keyword.get(opts, :language, nil)
    goal = Keyword.get(opts, :goal, :readability)

    language_hint = if language do
      "This is #{language} code."
    else
      ""
    end

    goal_instruction = case goal do
      :readability -> "Improve readability and maintainability."
      :performance -> "Optimize for better performance."
      :dry -> "Reduce code duplication (DRY principle)."
      :modular -> "Break into smaller, reusable functions."
      :modern -> "Update to use modern language features."
      _ -> "Improve overall code quality."
    end

    prompt = """
    You are a code refactoring expert. Refactor this code.

    #{language_hint}
    Goal: #{goal_instruction}

    Original code:
    ```
    #{code}
    ```

    Provide:
    1. The refactored code
    2. Summary of changes made
    3. Why each change improves the code

    Keep the same functionality while improving the code.
    """

    case AiEngine.generate(prompt, max_new_tokens: 800) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Generate code from a description.
  """
  def generate_code(description, language \\ :python) do
    prompt = """
    You are an expert #{language} programmer. Write code based on this description:

    Description: #{description}

    Requirements:
    - Write clean, idiomatic #{language} code
    - Include helpful comments
    - Handle edge cases
    - Follow best practices for #{language}

    Write only the code with comments. No additional explanation.
    """

    case AiEngine.generate(prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Compare two code snippets.
  """
  def compare(code1, code2, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    language_hint = if language do
      "Both snippets are in #{language}."
    else
      ""
    end

    prompt = """
    You are a code analysis expert. Compare these two code snippets.

    #{language_hint}

    Code A:
    ```
    #{code1}
    ```

    Code B:
    ```
    #{code2}
    ```

    Compare:
    1. Functional differences (do they produce the same output?)
    2. Performance differences
    3. Readability/maintainability
    4. Which approach is better and why

    Be objective and explain trade-offs.
    """

    case AiEngine.generate(prompt, max_new_tokens: 600) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end

  @doc """
  Generate test cases for code.
  """
  def generate_tests(code, opts \\ []) do
    language = Keyword.get(opts, :language, :python)
    framework = Keyword.get(opts, :framework, nil)

    framework_note = case {language, framework} do
      {:python, nil} -> "Use pytest or unittest."
      {:python, f} -> "Use #{f}."
      {:javascript, nil} -> "Use Jest."
      {:javascript, f} -> "Use #{f}."
      {:elixir, _} -> "Use ExUnit."
      {:rust, _} -> "Use Rust's built-in testing."
      {_, nil} -> "Use the standard testing framework for #{language}."
      {_, f} -> "Use #{f}."
    end

    prompt = """
    You are a testing expert. Generate test cases for this code.

    Language: #{language}
    #{framework_note}

    Code to test:
    ```
    #{code}
    ```

    Generate:
    1. Normal/happy path test cases
    2. Edge case tests
    3. Error handling tests (if applicable)

    Write complete, runnable test code.
    """

    case AiEngine.generate(prompt, max_new_tokens: 700) do
      {:ok, result} -> {:ok, String.trim(result)}
      error -> error
    end
  end
end
