defmodule PureGopherAi.CodeAssistant do
  @moduledoc """
  AI-powered code assistant for PureGopherAI.

  Provides code generation, explanation, review, and conversion capabilities
  using the AI engine.

  Features:
  - Generate code from descriptions
  - Explain existing code
  - Review code for issues
  - Convert between programming languages
  - Streaming output support
  """

  require Logger

  alias PureGopherAi.AiEngine

  @supported_languages [
    {"elixir", "Elixir"},
    {"python", "Python"},
    {"javascript", "JavaScript"},
    {"typescript", "TypeScript"},
    {"ruby", "Ruby"},
    {"go", "Go"},
    {"rust", "Rust"},
    {"c", "C"},
    {"cpp", "C++"},
    {"java", "Java"},
    {"kotlin", "Kotlin"},
    {"swift", "Swift"},
    {"php", "PHP"},
    {"shell", "Shell/Bash"},
    {"sql", "SQL"},
    {"html", "HTML"},
    {"css", "CSS"},
    {"lua", "Lua"},
    {"perl", "Perl"},
    {"r", "R"},
    {"scala", "Scala"},
    {"haskell", "Haskell"},
    {"clojure", "Clojure"},
    {"erlang", "Erlang"}
  ]

  @doc """
  Lists all supported programming languages.
  """
  def supported_languages, do: @supported_languages

  @doc """
  Gets the full name of a language from its code.
  """
  def language_name(code) do
    code = String.downcase(code)
    case Enum.find(@supported_languages, fn {c, _name} -> c == code end) do
      {_code, name} -> name
      nil -> String.capitalize(code)
    end
  end

  @doc """
  Generates code from a description.
  """
  def generate(language, description, opts \\ []) do
    lang_name = language_name(language)

    prompt = """
    Generate #{lang_name} code for the following task:
    #{description}

    Requirements:
    - Write clean, idiomatic #{lang_name} code
    - Include brief comments explaining key parts
    - Handle edge cases appropriately
    - Keep the code concise but complete

    #{lang_name} code:
    """

    AiEngine.generate(prompt, opts)
  end

  @doc """
  Generates code with streaming output.
  """
  def generate_stream(language, description, callback, _opts \\ []) do
    lang_name = language_name(language)

    prompt = """
    Generate #{lang_name} code for the following task:
    #{description}

    Requirements:
    - Write clean, idiomatic #{lang_name} code
    - Include brief comments explaining key parts
    - Handle edge cases appropriately
    - Keep the code concise but complete

    #{lang_name} code:
    """

    AiEngine.generate_stream(prompt, nil, callback)
  end

  @doc """
  Explains what a piece of code does.
  """
  def explain(code, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    lang_hint = if language do
      "This is #{language_name(language)} code."
    else
      "Detect the programming language automatically."
    end

    prompt = """
    Explain what the following code does:

    ```
    #{code}
    ```

    #{lang_hint}

    Provide a clear explanation that covers:
    1. Overall purpose of the code
    2. Key functions/methods and what they do
    3. Important data structures used
    4. Any notable patterns or techniques

    Keep the explanation concise but informative.

    Explanation:
    """

    AiEngine.generate(prompt, opts)
  end

  @doc """
  Explains code with streaming output.
  """
  def explain_stream(code, callback, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    lang_hint = if language do
      "This is #{language_name(language)} code."
    else
      "Detect the programming language automatically."
    end

    prompt = """
    Explain what the following code does:

    ```
    #{code}
    ```

    #{lang_hint}

    Provide a clear explanation that covers:
    1. Overall purpose of the code
    2. Key functions/methods and what they do
    3. Important data structures used
    4. Any notable patterns or techniques

    Keep the explanation concise but informative.

    Explanation:
    """

    AiEngine.generate_stream(prompt, nil, callback)
  end

  @doc """
  Reviews code for issues and improvements.
  """
  def review(code, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    lang_hint = if language do
      "This is #{language_name(language)} code."
    else
      "Detect the programming language automatically."
    end

    prompt = """
    Review the following code for issues and improvements:

    ```
    #{code}
    ```

    #{lang_hint}

    Provide a code review that covers:
    1. Potential bugs or issues
    2. Performance concerns
    3. Security vulnerabilities (if any)
    4. Code style and readability
    5. Suggested improvements

    Be constructive and specific. If the code is good, acknowledge that.

    Code Review:
    """

    AiEngine.generate(prompt, opts)
  end

  @doc """
  Reviews code with streaming output.
  """
  def review_stream(code, callback, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    lang_hint = if language do
      "This is #{language_name(language)} code."
    else
      "Detect the programming language automatically."
    end

    prompt = """
    Review the following code for issues and improvements:

    ```
    #{code}
    ```

    #{lang_hint}

    Provide a code review that covers:
    1. Potential bugs or issues
    2. Performance concerns
    3. Security vulnerabilities (if any)
    4. Code style and readability
    5. Suggested improvements

    Be constructive and specific. If the code is good, acknowledge that.

    Code Review:
    """

    AiEngine.generate_stream(prompt, nil, callback)
  end

  @doc """
  Converts code from one language to another.
  """
  def convert(code, from_language, to_language, opts \\ []) do
    from_name = language_name(from_language)
    to_name = language_name(to_language)

    prompt = """
    Convert the following #{from_name} code to #{to_name}:

    ```#{from_language}
    #{code}
    ```

    Requirements:
    - Preserve the original functionality exactly
    - Use idiomatic #{to_name} patterns and conventions
    - Include equivalent comments
    - Handle any language-specific differences appropriately

    #{to_name} code:
    """

    AiEngine.generate(prompt, opts)
  end

  @doc """
  Converts code with streaming output.
  """
  def convert_stream(code, from_language, to_language, callback, _opts \\ []) do
    from_name = language_name(from_language)
    to_name = language_name(to_language)

    prompt = """
    Convert the following #{from_name} code to #{to_name}:

    ```#{from_language}
    #{code}
    ```

    Requirements:
    - Preserve the original functionality exactly
    - Use idiomatic #{to_name} patterns and conventions
    - Include equivalent comments
    - Handle any language-specific differences appropriately

    #{to_name} code:
    """

    AiEngine.generate_stream(prompt, nil, callback)
  end

  @doc """
  Fixes code based on an error message.
  """
  def fix(code, error_message, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    lang_hint = if language do
      "This is #{language_name(language)} code."
    else
      ""
    end

    prompt = """
    Fix the following code that produces this error:

    Error:
    #{error_message}

    Code:
    ```
    #{code}
    ```

    #{lang_hint}

    Provide:
    1. Explanation of what caused the error
    2. The corrected code
    3. Brief explanation of the fix

    Fixed code:
    """

    AiEngine.generate(prompt, opts)
  end

  @doc """
  Fixes code with streaming output.
  """
  def fix_stream(code, error_message, callback, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    lang_hint = if language do
      "This is #{language_name(language)} code."
    else
      ""
    end

    prompt = """
    Fix the following code that produces this error:

    Error:
    #{error_message}

    Code:
    ```
    #{code}
    ```

    #{lang_hint}

    Provide:
    1. Explanation of what caused the error
    2. The corrected code
    3. Brief explanation of the fix

    Fixed code:
    """

    AiEngine.generate_stream(prompt, nil, callback)
  end

  @doc """
  Generates a regex pattern from a description.
  """
  def regex(description, opts \\ []) do
    flavor = Keyword.get(opts, :flavor, "PCRE")

    prompt = """
    Generate a #{flavor} regular expression for the following:
    #{description}

    Provide:
    1. The regex pattern
    2. Explanation of each part
    3. Example matches and non-matches

    Regex:
    """

    AiEngine.generate(prompt, opts)
  end

  @doc """
  Optimizes code for performance.
  """
  def optimize(code, opts \\ []) do
    language = Keyword.get(opts, :language, nil)

    lang_hint = if language do
      "This is #{language_name(language)} code."
    else
      ""
    end

    prompt = """
    Optimize the following code for better performance:

    ```
    #{code}
    ```

    #{lang_hint}

    Provide:
    1. Analysis of current performance characteristics
    2. Optimized version of the code
    3. Explanation of optimizations made
    4. Expected performance improvement

    Optimized code:
    """

    AiEngine.generate(prompt, opts)
  end
end
