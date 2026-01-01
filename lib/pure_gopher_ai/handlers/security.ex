defmodule PureGopherAi.Handlers.Security do
  @moduledoc """
  Security-related route handlers.

  Handles:
  - Session management (login, logout, token refresh)
  - Audit log viewing (admin only)
  - CAPTCHA challenges
  - Security status/stats
  """

  alias PureGopherAi.Session
  alias PureGopherAi.AuditLog
  alias PureGopherAi.Admin
  alias PureGopherAi.Captcha
  alias PureGopherAi.Handlers.Shared

  # === Session Management ===

  @doc "Login prompt"
  def login_prompt(host, port) do
    """
    i=== Login ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iGet a session token for authenticated actions.\t\t#{host}\t#{port}
    iTokens are valid for 30 minutes.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iFormat: username:passphrase\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iEnter credentials:\t\t#{host}\t#{port}
    .
    """
  end

  @doc "Handle login and create session"
  def handle_login(input, ip, host, port) do
    input = String.trim(input)

    case String.split(input, ":", parts: 2) do
      [username, passphrase] when byte_size(passphrase) > 0 ->
        username = String.trim(username)
        passphrase = String.trim(passphrase)

        case Session.login(username, passphrase, ip: ip) do
          {:ok, token} ->
            AuditLog.auth_success(username, ip: ip)
            AuditLog.session_created(username, ip: ip)

            """
            i=== Login Successful ===\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iWelcome, #{username}!\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iYour session token (valid 30 min):\t\t#{host}\t#{port}
            i#{token}\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iUse this token for authenticated actions:\t\t#{host}\t#{port}
            i  /auth/action?token=YOUR_TOKEN\t\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            iTo logout:\t\t#{host}\t#{port}
            0Logout\t/auth/logout/#{token}\t#{host}\t#{port}
            i\t\t#{host}\t#{port}
            1Back to Home\t/\t#{host}\t#{port}
            .
            """

          {:error, :not_found} ->
            AuditLog.auth_failure(username, :not_found, ip: ip)
            Shared.error_response("User not found: #{username}")

          {:error, :invalid_credentials} ->
            AuditLog.auth_failure(username, :invalid_credentials, ip: ip)
            Shared.error_response("Invalid passphrase")

          {:error, :brute_force_blocked} ->
            AuditLog.auth_failure(username, :brute_force_blocked, ip: ip, severity: :warning)
            Shared.error_response("Too many failed attempts. Please wait before trying again.")

          {:error, reason} ->
            AuditLog.auth_failure(username, reason, ip: ip)
            Shared.error_response("Login failed: #{reason}")
        end

      _ ->
        Shared.error_response("Invalid format. Use: username:passphrase")
    end
  end

  @doc "Handle logout (invalidate session)"
  def handle_logout(token, ip, host, port) do
    case Session.get_info(token) do
      {:ok, session} ->
        Session.invalidate(token)
        AuditLog.session_invalidated(session.username, ip: ip)

        """
        i=== Logged Out ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iYour session has been ended.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        7Login Again\t/auth/login\t#{host}\t#{port}
        1Back to Home\t/\t#{host}\t#{port}
        .
        """

      {:error, :not_found} ->
        Shared.error_response("Session not found or already expired")
    end
  end

  @doc "Validate token and return status"
  def handle_validate(token, _ip, host, port) do
    case Session.validate(token) do
      {:ok, username} ->
        {:ok, session} = Session.get_info(token)
        expires_in = div(session.expires_at - System.monotonic_time(:millisecond), 60_000)

        """
        i=== Session Valid ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iUsername: #{username}\t\t#{host}\t#{port}
        iExpires in: #{expires_in} minutes\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        0Refresh Token\t/auth/refresh/#{token}\t#{host}\t#{port}
        0Logout\t/auth/logout/#{token}\t#{host}\t#{port}
        .
        """

      {:error, :expired} ->
        Shared.error_response("Session expired. Please login again.")

      {:error, :invalid_token} ->
        Shared.error_response("Invalid session token")
    end
  end

  @doc "Refresh session token"
  def handle_refresh(token, _ip, host, port) do
    case Session.refresh(token) do
      :ok ->
        {:ok, _session} = Session.get_info(token)

        """
        i=== Session Refreshed ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iYour session has been extended.\t\t#{host}\t#{port}
        iNew expiration: 30 minutes from now\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iToken: #{token}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        0Logout\t/auth/logout/#{token}\t#{host}\t#{port}
        1Back to Home\t/\t#{host}\t#{port}
        .
        """

      {:error, :expired} ->
        Shared.error_response("Session expired. Please login again.")

      {:error, :invalid_token} ->
        Shared.error_response("Invalid session token")
    end
  end

  @doc "Session status page"
  def session_menu(host, port) do
    stats = Session.stats()

    """
    i=== Session Management ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iManage your authentication session.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Login (get token)\t/auth/login\t#{host}\t#{port}
    7Validate Token\t/auth/validate\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i--- System Stats ---\t\t#{host}\t#{port}
    iActive sessions: #{stats.active_sessions}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Back to Home\t/\t#{host}\t#{port}
    .
    """
  end

  # === Audit Log Viewing (Admin Only) ===

  @doc "Audit log menu (admin only)"
  def audit_menu(admin_token, host, port) do
    if Admin.valid_token?(admin_token) do
      {:ok, stats} = AuditLog.stats()

      """
      i=== Audit Log ===\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      i--- Statistics ---\t\t#{host}\t#{port}
      iTotal entries: #{stats[:total] || 0}\t\t#{host}\t#{port}
      iAuth events: #{stats[:auth] || 0}\t\t#{host}\t#{port}
      iAdmin events: #{stats[:admin] || 0}\t\t#{host}\t#{port}
      iSecurity events: #{stats[:security] || 0}\t\t#{host}\t#{port}
      iContent events: #{stats[:content] || 0}\t\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      i--- Views ---\t\t#{host}\t#{port}
      1Recent Events\t/admin/#{admin_token}/audit/recent\t#{host}\t#{port}
      1Security Events\t/admin/#{admin_token}/audit/security\t#{host}\t#{port}
      1Auth Events\t/admin/#{admin_token}/audit/auth\t#{host}\t#{port}
      7Search by IP\t/admin/#{admin_token}/audit/ip\t#{host}\t#{port}
      7Search by User\t/admin/#{admin_token}/audit/user\t#{host}\t#{port}
      i\t\t#{host}\t#{port}
      1Back to Admin\t/admin/#{admin_token}\t#{host}\t#{port}
      .
      """
    else
      Shared.error_response("Invalid admin token")
    end
  end

  @doc "View recent audit events"
  def audit_recent(admin_token, host, port) do
    if Admin.valid_token?(admin_token) do
      {:ok, entries} = AuditLog.recent(50)
      format_audit_entries(entries, "Recent Events", admin_token, host, port)
    else
      Shared.error_response("Invalid admin token")
    end
  end

  @doc "View security events"
  def audit_security(admin_token, host, port) do
    if Admin.valid_token?(admin_token) do
      {:ok, entries} = AuditLog.security_events(limit: 50)
      format_audit_entries(entries, "Security Events", admin_token, host, port)
    else
      Shared.error_response("Invalid admin token")
    end
  end

  @doc "View auth events"
  def audit_auth(admin_token, host, port) do
    if Admin.valid_token?(admin_token) do
      {:ok, entries} = AuditLog.auth_events(limit: 50)
      format_audit_entries(entries, "Auth Events", admin_token, host, port)
    else
      Shared.error_response("Invalid admin token")
    end
  end

  @doc "Search by IP"
  def audit_by_ip(admin_token, ip, host, port) do
    if Admin.valid_token?(admin_token) do
      {:ok, entries} = AuditLog.by_ip(ip, limit: 50)
      format_audit_entries(entries, "Events for IP: #{ip}", admin_token, host, port)
    else
      Shared.error_response("Invalid admin token")
    end
  end

  @doc "Search by user"
  def audit_by_user(admin_token, username, host, port) do
    if Admin.valid_token?(admin_token) do
      {:ok, entries} = AuditLog.by_user(username, limit: 50)
      format_audit_entries(entries, "Events for User: #{username}", admin_token, host, port)
    else
      Shared.error_response("Invalid admin token")
    end
  end

  # === CAPTCHA Challenges ===

  @doc "Check if CAPTCHA is required for an action on this network"
  def captcha_required?(action, network), do: Captcha.required?(action, network)

  @doc "Generate a CAPTCHA challenge prompt"
  def captcha_prompt(action, return_path, host, port) do
    {challenge_id, question} = Captcha.create_challenge()
    encoded_return = Base.url_encode64(return_path, padding: false)

    """
    i=== Security Check ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    iPlease complete this challenge to continue.\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    i#{question}\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    7Answer\t/captcha/verify/#{action}/#{challenge_id}/#{encoded_return}\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    1Cancel\t/\t#{host}\t#{port}
    .
    """
  end

  @doc "Handle CAPTCHA verification"
  def handle_captcha_verify(action, challenge_id, encoded_return, response, host, port) do
    case Captcha.verify(challenge_id, response) do
      :ok ->
        # Mark any pending action as verified
        Captcha.mark_verified(challenge_id)

        return_path = case Base.url_decode64(encoded_return, padding: false) do
          {:ok, path} -> path
          :error -> "/"
        end

        """
        i=== Verified ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iCAPTCHA verified successfully.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iYou can now proceed with: #{action}\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Continue\t#{return_path}?captcha=#{challenge_id}\t#{host}\t#{port}
        .
        """

      {:error, :incorrect} ->
        """
        i=== Incorrect ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iIncorrect answer. Please try again.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Try Again\t/captcha/new/#{action}/#{encoded_return}\t#{host}\t#{port}
        1Cancel\t/\t#{host}\t#{port}
        .
        """

      {:error, :expired} ->
        """
        i=== Expired ===\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        iChallenge expired. Please try again.\t\t#{host}\t#{port}
        i\t\t#{host}\t#{port}
        1Try Again\t/captcha/new/#{action}/#{encoded_return}\t#{host}\t#{port}
        1Cancel\t/\t#{host}\t#{port}
        .
        """

      {:error, _} ->
        Shared.error_response("Invalid challenge")
    end
  end

  @doc "Create a new CAPTCHA challenge"
  def handle_new_captcha(action, encoded_return, host, port) do
    return_path = case Base.url_decode64(encoded_return, padding: false) do
      {:ok, path} -> path
      :error -> "/"
    end

    captcha_prompt(action, return_path, host, port)
  end

  # === Private Helpers ===

  defp format_audit_entries(entries, title, admin_token, host, port) do
    entry_lines = if Enum.empty?(entries) do
      "iNo entries found.\t\t#{host}\t#{port}"
    else
      entries
      |> Enum.map(fn e ->
        timestamp = Calendar.strftime(e.timestamp, "%Y-%m-%d %H:%M:%S")
        severity_icon = case e.severity do
          :info -> " "
          :warning -> "!"
          :error -> "X"
          :critical -> "!!"
        end
        user = if e.username, do: " [#{e.username}]", else: ""
        ip = if e.ip, do: " (#{e.ip})", else: ""

        "i#{severity_icon} #{timestamp} #{e.category}:#{e.event}#{user}#{ip}\t\t#{host}\t#{port}"
      end)
      |> Enum.join("\r\n")
    end

    """
    i=== #{title} ===\t\t#{host}\t#{port}
    i\t\t#{host}\t#{port}
    #{entry_lines}
    i\t\t#{host}\t#{port}
    1Back to Audit Log\t/admin/#{admin_token}/audit\t#{host}\t#{port}
    .
    """
  end
end
