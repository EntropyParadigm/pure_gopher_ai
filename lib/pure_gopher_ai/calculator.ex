defmodule PureGopherAi.Calculator do
  @moduledoc """
  Simple calculator for evaluating mathematical expressions.

  Supports:
  - Basic arithmetic: +, -, *, /
  - Parentheses for grouping
  - Common functions: sqrt, abs, sin, cos, tan, log, exp, pow
  - Constants: pi, e
  - Modulo: mod or %
  - Exponentiation: ^ or **
  """

  @doc """
  Evaluates a mathematical expression.
  Returns {:ok, result} or {:error, reason}.
  """
  def evaluate(expression) do
    expression = expression
      |> String.trim()
      |> String.downcase()
      |> normalize_expression()

    try do
      case parse_and_evaluate(expression) do
        {:ok, result} when is_number(result) ->
          {:ok, result, format_result(result)}
        {:error, reason} ->
          {:error, reason}
        _ ->
          {:error, :invalid_expression}
      end
    rescue
      ArithmeticError -> {:error, :arithmetic_error}
      _ -> {:error, :evaluation_error}
    end
  end

  @doc """
  Returns examples of valid expressions.
  """
  def examples do
    [
      "2 + 2",
      "10 * 5 - 3",
      "(4 + 6) / 2",
      "sqrt(16)",
      "2 ^ 10",
      "pi * 2",
      "sin(pi/2)",
      "log(100)",
      "abs(-5)"
    ]
  end

  @doc """
  Returns available functions.
  """
  def functions do
    [
      %{name: "sqrt(x)", description: "Square root"},
      %{name: "abs(x)", description: "Absolute value"},
      %{name: "sin(x)", description: "Sine (radians)"},
      %{name: "cos(x)", description: "Cosine (radians)"},
      %{name: "tan(x)", description: "Tangent (radians)"},
      %{name: "log(x)", description: "Natural logarithm"},
      %{name: "log10(x)", description: "Base-10 logarithm"},
      %{name: "exp(x)", description: "e^x"},
      %{name: "pow(x,y)", description: "x^y"},
      %{name: "floor(x)", description: "Round down"},
      %{name: "ceil(x)", description: "Round up"},
      %{name: "round(x)", description: "Round to nearest"}
    ]
  end

  @doc """
  Returns available constants.
  """
  def constants do
    [
      %{name: "pi", value: :math.pi()},
      %{name: "e", value: :math.exp(1)}
    ]
  end

  # Private functions

  defp normalize_expression(expr) do
    expr
    # Replace constants
    |> String.replace("pi", "(#{:math.pi()})")
    |> String.replace(~r/\be\b/, "(#{:math.exp(1)})")
    # Normalize operators
    |> String.replace("**", "^")
    |> String.replace("mod", "%")
    # Remove extra spaces
    |> String.replace(~r/\s+/, " ")
  end

  defp parse_and_evaluate(expr) do
    # Tokenize
    case tokenize(expr) do
      {:ok, tokens} ->
        # Convert to postfix (RPN) and evaluate
        case to_postfix(tokens) do
          {:ok, postfix} -> evaluate_postfix(postfix)
          error -> error
        end
      error -> error
    end
  end

  defp tokenize(expr) do
    # Pattern for numbers (including decimals and negatives at start)
    # Pattern for operators and parentheses
    # Pattern for function names

    tokens = Regex.scan(
      ~r/(\d+\.?\d*|[+\-*\/^%()]|sqrt|abs|sin|cos|tan|log10|log|exp|pow|floor|ceil|round|,)/,
      expr
    )
    |> Enum.map(fn [match | _] -> categorize_token(match) end)

    if Enum.any?(tokens, &(&1 == :error)) do
      {:error, :invalid_token}
    else
      {:ok, tokens}
    end
  end

  defp categorize_token(token) do
    cond do
      Regex.match?(~r/^\d+\.?\d*$/, token) ->
        {value, _} = Float.parse(token)
        {:number, value}

      token in ["+", "-", "*", "/", "^", "%"] ->
        {:operator, token}

      token == "(" -> :lparen
      token == ")" -> :rparen
      token == "," -> :comma

      token in ["sqrt", "abs", "sin", "cos", "tan", "log", "log10", "exp", "pow", "floor", "ceil", "round"] ->
        {:function, token}

      true ->
        :error
    end
  end

  # Shunting-yard algorithm for operator precedence
  defp to_postfix(tokens) do
    to_postfix(tokens, [], [])
  end

  defp to_postfix([], output, operators) do
    # Pop remaining operators
    remaining = Enum.reverse(operators)
    if Enum.any?(remaining, &(&1 == :lparen)) do
      {:error, :mismatched_parentheses}
    else
      {:ok, output ++ remaining}
    end
  end

  defp to_postfix([{:number, _} = token | rest], output, operators) do
    to_postfix(rest, output ++ [token], operators)
  end

  defp to_postfix([{:function, _} = token | rest], output, operators) do
    to_postfix(rest, output, [token | operators])
  end

  defp to_postfix([:comma | rest], output, operators) do
    # Pop operators until left paren
    {popped, remaining} = pop_until_lparen(operators)
    to_postfix(rest, output ++ popped, remaining)
  end

  defp to_postfix([{:operator, op} = token | rest], output, operators) do
    prec = precedence(op)
    assoc = associativity(op)

    {popped, remaining} = pop_while_higher_precedence(operators, prec, assoc)
    to_postfix(rest, output ++ popped, [token | remaining])
  end

  defp to_postfix([:lparen | rest], output, operators) do
    to_postfix(rest, output, [:lparen | operators])
  end

  defp to_postfix([:rparen | rest], output, operators) do
    {popped, remaining} = pop_until_lparen(operators)
    # Pop the left paren
    remaining = case remaining do
      [:lparen | r] -> r
      _ -> remaining
    end
    # If there's a function on top, pop it too
    {func, remaining} = case remaining do
      [{:function, _} = f | r] -> {[f], r}
      _ -> {[], remaining}
    end
    to_postfix(rest, output ++ popped ++ func, remaining)
  end

  defp pop_until_lparen(operators) do
    pop_until_lparen(operators, [])
  end

  defp pop_until_lparen([], acc), do: {Enum.reverse(acc), []}
  defp pop_until_lparen([:lparen | rest], acc), do: {Enum.reverse(acc), [:lparen | rest]}
  defp pop_until_lparen([op | rest], acc), do: pop_until_lparen(rest, [op | acc])

  defp pop_while_higher_precedence(operators, prec, assoc) do
    pop_while_higher_precedence(operators, prec, assoc, [])
  end

  defp pop_while_higher_precedence([], _prec, _assoc, acc), do: {Enum.reverse(acc), []}
  defp pop_while_higher_precedence([:lparen | _] = ops, _prec, _assoc, acc), do: {Enum.reverse(acc), ops}
  defp pop_while_higher_precedence([{:function, _} = f | rest], prec, assoc, acc) do
    pop_while_higher_precedence(rest, prec, assoc, [f | acc])
  end
  defp pop_while_higher_precedence([{:operator, op} = token | rest], prec, assoc, acc) do
    op_prec = precedence(op)
    should_pop = (assoc == :left and op_prec >= prec) or (assoc == :right and op_prec > prec)

    if should_pop do
      pop_while_higher_precedence(rest, prec, assoc, [token | acc])
    else
      {Enum.reverse(acc), [token | rest]}
    end
  end

  defp precedence(op) do
    case op do
      "+" -> 1
      "-" -> 1
      "*" -> 2
      "/" -> 2
      "%" -> 2
      "^" -> 3
      _ -> 0
    end
  end

  defp associativity(op) do
    case op do
      "^" -> :right
      _ -> :left
    end
  end

  # Evaluate postfix expression
  defp evaluate_postfix(tokens) do
    evaluate_postfix(tokens, [])
  end

  defp evaluate_postfix([], [result]), do: {:ok, result}
  defp evaluate_postfix([], _), do: {:error, :invalid_expression}

  defp evaluate_postfix([{:number, n} | rest], stack) do
    evaluate_postfix(rest, [n | stack])
  end

  defp evaluate_postfix([{:operator, op} | rest], [b, a | stack]) do
    result = apply_operator(op, a, b)
    evaluate_postfix(rest, [result | stack])
  end

  defp evaluate_postfix([{:operator, _} | _], _stack) do
    {:error, :insufficient_operands}
  end

  defp evaluate_postfix([{:function, func} | rest], stack) do
    case apply_function(func, stack) do
      {:ok, result, remaining} -> evaluate_postfix(rest, [result | remaining])
      error -> error
    end
  end

  defp apply_operator("+", a, b), do: a + b
  defp apply_operator("-", a, b), do: a - b
  defp apply_operator("*", a, b), do: a * b
  defp apply_operator("/", _a, +0.0), do: raise ArithmeticError
  defp apply_operator("/", _a, 0), do: raise ArithmeticError
  defp apply_operator("/", a, b), do: a / b
  defp apply_operator("^", a, b), do: :math.pow(a, b)
  defp apply_operator("%", a, b), do: rem(trunc(a), trunc(b))

  defp apply_function("sqrt", [a | rest]) when a >= 0, do: {:ok, :math.sqrt(a), rest}
  defp apply_function("sqrt", [_ | _]), do: {:error, :negative_sqrt}
  defp apply_function("abs", [a | rest]), do: {:ok, abs(a), rest}
  defp apply_function("sin", [a | rest]), do: {:ok, :math.sin(a), rest}
  defp apply_function("cos", [a | rest]), do: {:ok, :math.cos(a), rest}
  defp apply_function("tan", [a | rest]), do: {:ok, :math.tan(a), rest}
  defp apply_function("log", [a | rest]) when a > 0, do: {:ok, :math.log(a), rest}
  defp apply_function("log", [_ | _]), do: {:error, :invalid_log}
  defp apply_function("log10", [a | rest]) when a > 0, do: {:ok, :math.log10(a), rest}
  defp apply_function("log10", [_ | _]), do: {:error, :invalid_log}
  defp apply_function("exp", [a | rest]), do: {:ok, :math.exp(a), rest}
  defp apply_function("pow", [b, a | rest]), do: {:ok, :math.pow(a, b), rest}
  defp apply_function("floor", [a | rest]), do: {:ok, Float.floor(a), rest}
  defp apply_function("ceil", [a | rest]), do: {:ok, Float.ceil(a), rest}
  defp apply_function("round", [a | rest]), do: {:ok, Float.round(a), rest}
  defp apply_function(_, []), do: {:error, :insufficient_arguments}
  defp apply_function(_, _), do: {:error, :unknown_function}

  defp format_result(num) when is_float(num) do
    cond do
      num == Float.round(num, 0) and abs(num) < 1.0e15 ->
        :erlang.float_to_binary(num, decimals: 0)
      abs(num) >= 1.0e10 or abs(num) < 1.0e-6 ->
        :erlang.float_to_binary(num, scientific: 6)
      abs(num) >= 1 ->
        :erlang.float_to_binary(num, decimals: 8) |> String.trim_trailing("0") |> String.trim_trailing(".")
      true ->
        :erlang.float_to_binary(num, decimals: 10) |> String.trim_trailing("0") |> String.trim_trailing(".")
    end
  end

  defp format_result(num) when is_integer(num), do: to_string(num)
end
