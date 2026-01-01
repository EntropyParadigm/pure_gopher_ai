defmodule PureGopherAi.OutputSanitizer do
  @moduledoc """
  Sanitizes AI-generated output before sending to users.

  Provides protection against:
  - Accidental leakage of sensitive data (API keys, passwords)
  - System prompt leakage
  - Internal instruction exposure
  - Potentially harmful content

  ## Usage

      iex> OutputSanitizer.sanitize("The API key is sk-abc123")
      "The API key is [REDACTED]"

      iex> OutputSanitizer.sanitize("Normal response text")
      "Normal response text"
  """

  @doc """
  Sanitizes AI output, redacting sensitive patterns.

  ## Options
  - `:redact_secrets` - Redact API keys, passwords, etc. (default: true)
  - `:redact_system_prompts` - Redact system prompt leakage (default: true)
  - `:max_length` - Maximum output length (default: 10000)
  """
  def sanitize(output, opts \\ [])
  def sanitize(nil, _opts), do: ""

  def sanitize(output, opts) when is_binary(output) do
    redact_secrets = Keyword.get(opts, :redact_secrets, true)
    redact_system = Keyword.get(opts, :redact_system_prompts, true)
    max_length = Keyword.get(opts, :max_length, 10000)

    output
    |> maybe_redact_secrets(redact_secrets)
    |> maybe_redact_system_prompts(redact_system)
    |> String.slice(0, max_length)
  end

  @doc """
  Checks if output contains potentially sensitive content.

  Returns a map with detection results for monitoring.
  """
  def analyze(output) when is_binary(output) do
    %{
      has_api_keys: has_api_keys?(output),
      has_passwords: has_passwords?(output),
      has_system_leak: has_system_prompt_leak?(output),
      has_email: has_email?(output),
      has_ip_address: has_ip_address?(output),
      length: String.length(output)
    }
  end

  def analyze(_), do: %{error: :invalid_input}

  # Sensitive data patterns
  @api_key_patterns [
    # OpenAI
    ~r/sk-[a-zA-Z0-9]{20,}/,
    # Anthropic
    ~r/sk-ant-[a-zA-Z0-9\-]{20,}/,
    # AWS
    ~r/AKIA[0-9A-Z]{16}/,
    # Generic API key patterns
    ~r/api[_\-]?key[:\s=]+['"]?[a-zA-Z0-9\-_]{20,}/i,
    ~r/secret[_\-]?key[:\s=]+['"]?[a-zA-Z0-9\-_]{20,}/i,
    ~r/access[_\-]?token[:\s=]+['"]?[a-zA-Z0-9\-_]{20,}/i,
    # Bearer tokens
    ~r/bearer\s+[a-zA-Z0-9\-_\.]+/i,
    # GitHub tokens
    ~r/ghp_[a-zA-Z0-9]{36}/,
    ~r/gho_[a-zA-Z0-9]{36}/,
    # Generic hex secrets (32+ chars)
    ~r/['\"][a-f0-9]{32,}['"]/i
  ]

  @password_patterns [
    ~r/password[:\s=]+['"]?[^\s'"]{8,}/i,
    ~r/passwd[:\s=]+['"]?[^\s'"]{8,}/i,
    ~r/pwd[:\s=]+['"]?[^\s'"]{8,}/i,
    ~r/secret[:\s=]+['"]?[^\s'"]{8,}/i
  ]

  @system_prompt_patterns [
    ~r/<system>.*?<\/system>/is,
    ~r/\[SYSTEM\].*?\[\/SYSTEM\]/is,
    ~r/<<SYS>>.*?<<\/SYS>>/is,
    ~r/system\s*prompt[:\s]+.{20,}/i,
    ~r/my\s+instructions\s+(are|say|tell)/i,
    ~r/i\s+was\s+instructed\s+to/i,
    ~r/my\s+system\s+prompt/i
  ]

  # Chat template/instruction tags that may leak from the model
  @chat_template_patterns [
    # User/Assistant tags (complete)
    ~r/<\/?user_input>/i,
    ~r/<\/?user>/i,
    ~r/<\/?User>/i,
    ~r/<\/?assistant>/i,
    ~r/<\/?Assistant>/i,
    ~r/<\/?human>/i,
    ~r/<\/?Human>/i,
    ~r/<\/?bot>/i,
    ~r/<\/?Bot>/i,
    # Instruction markers
    ~r/^User:\s*$/m,
    ~r/^Assistant:\s*$/m,
    ~r/^Human:\s*$/m,
    ~r/^Bot:\s*$/m,
    # Incomplete/partial tags
    ~r/^\s*<\s*(user|assistant|human|bot)\s*$/mi,
    ~r/^\s*<\/\s*(user|assistant|human|bot)\s*$/mi,
    # Partial tag fragments that might appear
    ~r/^sistant>\s*$/mi,
    ~r/^ssistant>\s*$/mi,
    ~r/^istant>\s*$/mi,
    ~r/^stant>\s*$/mi,
    ~r/^ant>\s*$/mi,
    ~r/^nt>\s*$/mi,
    ~r/^ser>\s*$/mi,
    ~r/^uman>\s*$/mi,
    ~r/^man>\s*$/mi,
    ~r/^an>\s*$/mi,
    # Lines that are just closing angle brackets
    ~r/^\s*>\s*$/m,
    # Lines that look like tag fragments
    ~r/^\s*<\/?\s*$/m
  ]

  defp maybe_redact_secrets(output, true) do
    output
    |> redact_patterns(@api_key_patterns, "[REDACTED_API_KEY]")
    |> redact_patterns(@password_patterns, "[REDACTED_PASSWORD]")
    |> redact_email()
    |> redact_private_ip()
  end

  defp maybe_redact_secrets(output, false), do: output

  defp maybe_redact_system_prompts(output, true) do
    output
    |> redact_patterns(@system_prompt_patterns, "[SYSTEM_CONTENT_REDACTED]")
    |> strip_chat_template_tags()
  end

  defp maybe_redact_system_prompts(output, false), do: output

  defp strip_chat_template_tags(output) do
    # Remove chat template tags entirely (don't redact, just strip)
    Enum.reduce(@chat_template_patterns, output, fn pattern, acc ->
      Regex.replace(pattern, acc, "")
    end)
    |> String.replace(~r/\n{3,}/, "\n\n")  # Clean up excessive newlines
    |> String.trim()
  end

  defp redact_patterns(text, patterns, replacement) do
    Enum.reduce(patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp redact_email(text) do
    # Redact email addresses but keep domain visible
    Regex.replace(
      ~r/([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/,
      text,
      "[EMAIL]@\\2"
    )
  end

  defp redact_private_ip(text) do
    # Redact private IP addresses
    text
    |> String.replace(~r/\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, "[PRIVATE_IP]")
    |> String.replace(~r/\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b/, "[PRIVATE_IP]")
    |> String.replace(~r/\b192\.168\.\d{1,3}\.\d{1,3}\b/, "[PRIVATE_IP]")
  end

  defp has_api_keys?(text) do
    Enum.any?(@api_key_patterns, &Regex.match?(&1, text))
  end

  defp has_passwords?(text) do
    Enum.any?(@password_patterns, &Regex.match?(&1, text))
  end

  defp has_system_prompt_leak?(text) do
    Enum.any?(@system_prompt_patterns, &Regex.match?(&1, text))
  end

  defp has_email?(text) do
    Regex.match?(~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/, text)
  end

  defp has_ip_address?(text) do
    Regex.match?(~r/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, text)
  end
end
