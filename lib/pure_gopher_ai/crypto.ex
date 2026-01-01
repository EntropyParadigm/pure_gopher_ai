defmodule PureGopherAi.Crypto do
  @moduledoc """
  Cryptographic utilities for encryption at rest.

  Uses AES-256-GCM for symmetric encryption with a server-managed key.
  The encryption key is derived from a passphrase stored in the data directory.
  """

  @key_file "encryption.key"
  @aad "PureGopherAI_v1"

  @doc """
  Encrypts data using AES-256-GCM.
  Returns Base64-encoded string: IV || ciphertext || tag
  """
  def encrypt(plaintext) when is_binary(plaintext) do
    key = get_or_create_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} = :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      key,
      iv,
      plaintext,
      @aad,
      true
    )

    Base.encode64(iv <> ciphertext <> tag)
  end

  def encrypt(nil), do: nil
  def encrypt(data), do: encrypt(to_string(data))

  @doc """
  Decrypts AES-256-GCM encrypted data.
  Returns plaintext or {:error, :decryption_failed}
  """
  def decrypt(encoded) when is_binary(encoded) and byte_size(encoded) > 0 do
    key = get_or_create_key()

    case Base.decode64(encoded) do
      {:ok, data} when byte_size(data) > 28 ->
        # IV: 12 bytes, Tag: 16 bytes, rest is ciphertext
        iv = binary_part(data, 0, 12)
        # ciphertext is everything between IV and tag
        ciphertext_len = byte_size(data) - 12 - 16
        ciphertext = binary_part(data, 12, ciphertext_len)
        tag = binary_part(data, byte_size(data), -16)

        case :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          iv,
          ciphertext,
          @aad,
          tag,
          false
        ) do
          plaintext when is_binary(plaintext) ->
            {:ok, plaintext}
          :error ->
            {:error, :decryption_failed}
        end

      {:ok, _} ->
        {:error, :invalid_data}

      :error ->
        {:error, :invalid_base64}
    end
  end

  def decrypt(nil), do: {:ok, nil}
  def decrypt(""), do: {:ok, ""}

  @doc """
  Safely decrypts, returning original value on failure (for backward compatibility).
  """
  def decrypt_or_original(value) do
    case decrypt(value) do
      {:ok, plaintext} -> plaintext
      {:error, _} -> value  # Return original (unencrypted legacy data)
    end
  end

  @doc """
  Hashes a passphrase using PBKDF2.
  """
  def hash_passphrase(passphrase, salt) when is_binary(passphrase) and is_binary(salt) do
    # PBKDF2-HMAC-SHA256 with 100,000 iterations
    :crypto.pbkdf2_hmac(:sha256, passphrase, salt, 100_000, 32)
    |> Base.encode64()
  end

  @doc """
  Generates a random salt.
  """
  def generate_salt do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  @doc """
  Verifies a passphrase against a stored hash.
  """
  def verify_passphrase(passphrase, stored_hash, salt) do
    computed_hash = hash_passphrase(passphrase, salt)
    # Constant-time comparison to prevent timing attacks
    :crypto.hash_equals(stored_hash, computed_hash)
  end

  # Private functions

  defp get_or_create_key do
    case Process.get(:encryption_key) do
      nil ->
        key = load_or_create_key()
        Process.put(:encryption_key, key)
        key
      key ->
        key
    end
  end

  defp load_or_create_key do
    data_dir = Application.get_env(:pure_gopher_ai, :data_dir, "~/.gopher/data")
    key_path = Path.join([Path.expand(data_dir), @key_file])

    case File.read(key_path) do
      {:ok, encoded_key} ->
        case Base.decode64(encoded_key) do
          {:ok, key} when byte_size(key) == 32 -> key
          _ -> create_new_key(key_path)
        end

      {:error, :enoent} ->
        create_new_key(key_path)

      {:error, _} ->
        create_new_key(key_path)
    end
  end

  defp create_new_key(key_path) do
    key = :crypto.strong_rand_bytes(32)
    encoded = Base.encode64(key)

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(key_path))

    # Write key with restricted permissions
    File.write!(key_path, encoded)
    File.chmod!(key_path, 0o600)

    require Logger
    Logger.info("[Crypto] Generated new encryption key")

    key
  end
end
