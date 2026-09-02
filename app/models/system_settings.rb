# One row, enforced by a check constraint on id = 1. Holds the global flags the PRD calls out:
# shadow mode (on by default), the manual halt, and why sync is paused.
class SystemSettings < ApplicationRecord
  # The one gate Phase 2's submission path asks before touching Schwab.
  def writes_allowed? = !shadow_mode? && !manual_halt?

  def self.instance = find_or_create_by!(id: 1)

  # The two halves of the token pause, under the same row lock so a re-auth landing mid-tick cannot be
  # marked paused: pause while the token is unusable (one audit per episode) and resume on a new token.
  def self.pause_for_token!
    transaction do
      settings = instance.lock!
      next nil if SchwabToken.usable?
      unless settings.sync_paused_reason
        settings.update!(sync_paused_reason: "Schwab token unusable; re-authenticate")
        AuditEvent.log("sync_paused_token_expired", actor: :system)
      end
      settings.sync_paused_reason
    end
  end

  def self.resume_sync!
    settings = instance.lock!
    AuditEvent.log("sync_resumed", actor: :system, reason: settings.sync_paused_reason) if settings.sync_paused_reason
    settings.update!(sync_paused_reason: nil)
  end
end
