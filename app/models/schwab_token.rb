# One row per authorization-code grant. The newest row is current; older rows are history.
# Pause state is derived from the current token (usable?), never written by a failure.
class SchwabToken < ApplicationRecord
  REFRESH_LIFETIME = 168.hours # elapsed time, not calendar days; never extended by a refresh
  ACCESS_MARGIN = 60.seconds
  REFRESH_DEBOUNCE = 1.minute
  REFRESH_AHEAD = 5.minutes
  EXPIRING_SOON = 24.hours
  SUNDAY_EMAIL_HOUR = 18
  PAUSE_REASON = "Schwab refresh token rejected; re-authenticate"

  encrypts :access_token, :refresh_token

  def self.current = order(issued_at: :desc, id: :desc).first

  def self.usable? = current&.usable? || false

  # The coming Sunday ritual email: today's if it is Sunday before the hour, else next Sunday's.
  def self.next_sunday_email(now = Time.current)
    today = now.beginning_of_day.change(hour: SUNDAY_EMAIL_HOUR)
    return today if now.sunday? && now < today
    now.next_occurring(:sunday).beginning_of_day.change(hour: SUNDAY_EMAIL_HOUR)
  end

  def self.most_recent_sunday_email(now = Time.current) = now.beginning_of_week(:sunday).change(hour: SUNDAY_EMAIL_HOUR)

  # The one taxonomy every screen and email uses.
  def self.status(token = current)
    return :missing if token.nil?
    return :revoked if token.revoked?
    return :expired if token.refresh_expired?
    return :expiring if token.refresh_expiring_soon?
    :healthy
  end

  # A successful code exchange. The new row and the cleared pause commit together (the settings row lock
  # serializes this against a stale refresh trying to pause), then sync catches up.
  def self.issue!(response, now: Time.current)
    token = transaction do
      settings = SystemSettings.instance.lock!
      AuditEvent.log("sync_resumed", actor: :system, reason: settings.sync_paused_reason) if settings.sync_paused_reason
      settings.update!(sync_paused_reason: nil)
      create!(access_token: response.fetch("access_token"), refresh_token: response.fetch("refresh_token"),
              access_expires_at: now + response.fetch("expires_in").to_i.seconds - ACCESS_MARGIN,
              refresh_expires_at: now + REFRESH_LIFETIME, issued_at: now, scope: response["scope"])
    end
    Sync::CatchUpJob.perform_later
    token
  end

  def current? = self.class.current&.id == id
  def revoked? = revoked_at.present?
  def refresh_expired? = refresh_expires_at <= Time.current
  def access_expired? = access_expires_at <= Time.current
  def refresh_expiring_soon? = refresh_expires_at <= EXPIRING_SOON.from_now
  def usable? = !revoked? && !refresh_expired?
  def covered_by_sunday_email? = refresh_expires_at >= self.class.next_sunday_email

  # Refreshes the access token under the row lock. Reloads first, so a stale row does nothing and two
  # workers holding the same 401 refresh once. Must run outside any caller transaction: the failure record
  # below has to survive whatever the caller rolls back.
  def refresh!(wait: true)
    raise "SchwabToken#refresh! must not run inside a transaction" if self.class.connection.open_transactions > (Rails.env.test? ? 1 : 0)

    with_lock do
      next unless current? && usable?
      next if last_refreshed_at && last_refreshed_at > REFRESH_DEBOUNCE.ago
      apply_refresh(Schwab.oauth_client(wait: wait).refresh(refresh_token))
    end
  rescue Schwab::ReauthRequired => e
    record_failure(e, revoke: true)
    raise
  rescue Schwab::Error => e
    record_failure(e, revoke: false)
    raise
  end

  # Refresh ahead of expiry so a 401 is the safety net, not the routine path.
  def ensure_fresh!
    refresh! if access_expires_at <= REFRESH_AHEAD.from_now
    self
  end

  private
    def apply_refresh(response, now: Time.current)
      update!(access_token: response.fetch("access_token") { raise Schwab::MappingError, "token response without access_token" },
              refresh_token: response["refresh_token"].presence || refresh_token,
              access_expires_at: now + response.fetch("expires_in") { raise Schwab::MappingError, "token response without expires_in" }.to_i.seconds - ACCESS_MARGIN,
              last_refreshed_at: now, last_refresh_error: nil)
    end

    # The revoke-and-pause write is atomic with the currentness check: it holds the settings row lock,
    # which issue! also takes, so a token issued during the failed call cannot end up paused.
    def record_failure(error, revoke:)
      update_columns(last_refresh_error: error.message.truncate(500), updated_at: Time.current)
      return unless revoke
      SystemSettings.transaction do
        settings = SystemSettings.instance.lock!
        next unless current?
        update_columns(revoked_at: Time.current)
        settings.update!(sync_paused_reason: PAUSE_REASON)
        AuditEvent.log("token_refresh_failed", actor: :system, subject: self, reason: error.message.truncate(200), data: { status: error.status })
      end
    end
end
