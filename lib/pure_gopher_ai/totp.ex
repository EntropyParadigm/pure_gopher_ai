defmodule PureGopherAi.Totp do
  @moduledoc """
  Time-based One-Time Password (TOTP) implementation.

  Compatible with Google Authenticator, Authy, and other TOTP apps.
  Uses RFC 6238 TOTP algorithm with SHA1, 6 digits, 30-second windows.
  """

  @digits 6
  @period 30
  @algorithm :sha
  @secret_length 20

  @doc """
  Generates a new TOTP secret (base32 encoded).
  """
  def generate_secret do
    :crypto.strong_rand_bytes(@secret_length)
    |> Base.encode32(padding: false)
  end

  @doc """
  Generates a TOTP code for the given secret and time.
  """
  def generate_code(secret, time \\ nil) do
    time = time || System.system_time(:second)
    counter = div(time, @period)

    secret
    |> Base.decode32!(padding: false)
    |> hmac_sha1(counter)
    |> truncate()
    |> format_code()
  end

  @doc """
  Validates a TOTP code against a secret.
  Allows 1 window before and after current time for clock drift.
  """
  def validate(secret, code, time \\ nil) do
    time = time || System.system_time(:second)

    # Check current window and adjacent windows for clock drift
    Enum.any?([-1, 0, 1], fn offset ->
      adjusted_time = time + (offset * @period)
      generate_code(secret, adjusted_time) == normalize_code(code)
    end)
  end

  @doc """
  Generates a provisioning URI for QR code generation.
  Format: otpauth://totp/LABEL?secret=SECRET&issuer=ISSUER
  """
  def provisioning_uri(secret, username, issuer \\ "PureGopherAI") do
    label = URI.encode("#{issuer}:#{username}")
    params = URI.encode_query(%{
      "secret" => secret,
      "issuer" => issuer,
      "algorithm" => "SHA1",
      "digits" => @digits,
      "period" => @period
    })

    "otpauth://totp/#{label}?#{params}"
  end

  @doc """
  Generates an ASCII representation of the TOTP setup info.
  Since Gopher can't display QR codes, we provide manual entry info.
  """
  def setup_text(secret, username) do
    uri = provisioning_uri(secret, username)

    """
    ╔══════════════════════════════════════════════════════════════════╗
    ║               TWO-FACTOR AUTHENTICATION SETUP                   ║
    ╠══════════════════════════════════════════════════════════════════╣
    ║                                                                  ║
    ║  Add this account to your authenticator app:                     ║
    ║                                                                  ║
    ║  Account:  #{String.pad_trailing(username, 50)}║
    ║  Issuer:   PureGopherAI                                          ║
    ║                                                                  ║
    ║  Secret Key (enter manually):                                    ║
    ║  ┌────────────────────────────────────────────────────────────┐  ║
    ║  │ #{String.pad_trailing(format_secret(secret), 56)} │  ║
    ║  └────────────────────────────────────────────────────────────┘  ║
    ║                                                                  ║
    ║  Or scan this URI (if your client supports it):                  ║
    ║  #{String.pad_trailing(uri, 64)}║
    ║                                                                  ║
    ║  IMPORTANT: Save these backup codes before continuing!           ║
    ║                                                                  ║
    ╚══════════════════════════════════════════════════════════════════╝
    """
  end

  @doc """
  Generates backup codes for account recovery if TOTP device is lost.
  """
  def generate_backup_codes(count \\ 8) do
    Enum.map(1..count, fn _ ->
      :crypto.strong_rand_bytes(4)
      |> Base.encode16(case: :lower)
      |> String.split_at(4)
      |> then(fn {a, b} -> "#{a}-#{b}" end)
    end)
  end

  @doc """
  Hashes backup codes for storage.
  """
  def hash_backup_codes(codes) do
    Enum.map(codes, fn code ->
      normalized = String.replace(code, "-", "") |> String.downcase()
      :crypto.hash(:sha256, normalized) |> Base.encode64()
    end)
  end

  @doc """
  Validates a backup code against hashed codes.
  Returns {:ok, remaining_hashes} or {:error, :invalid_code}
  """
  def validate_backup_code(code, hashed_codes) do
    normalized = String.replace(code, "-", "") |> String.downcase()
    hash = :crypto.hash(:sha256, normalized) |> Base.encode64()

    if hash in hashed_codes do
      {:ok, List.delete(hashed_codes, hash)}
    else
      {:error, :invalid_code}
    end
  end

  # Private functions

  defp hmac_sha1(secret, counter) do
    counter_bytes = <<counter::unsigned-big-integer-size(64)>>
    :crypto.mac(:hmac, @algorithm, secret, counter_bytes)
  end

  defp truncate(hmac) do
    # Get offset from last nibble
    offset = :binary.at(hmac, 19) &&& 0x0F

    # Extract 4 bytes starting at offset
    <<_::binary-size(offset), p::unsigned-big-integer-size(32), _::binary>> = hmac

    # Clear the most significant bit and get modulo
    (p &&& 0x7FFFFFFF) |> rem(trunc(:math.pow(10, @digits)))
  end

  defp format_code(code) do
    code
    |> Integer.to_string()
    |> String.pad_leading(@digits, "0")
  end

  defp normalize_code(code) do
    code
    |> String.trim()
    |> String.replace(~r/\s+/, "")
    |> String.pad_leading(@digits, "0")
  end

  defp format_secret(secret) do
    secret
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(" ")
  end
end
