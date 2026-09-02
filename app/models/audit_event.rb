# Append-only. Every "logged" action in the PRD is a row here; the database triggers reject
# UPDATE, DELETE, and TRUNCATE, and Active Record refuses updates before it gets that far.
class AuditEvent < ApplicationRecord
  KINDS = %w[
    re_auth_succeeded re_auth_failed re_auth_missing_accounts token_refresh_failed sync_paused_token_expired sync_resumed
    token_nag_sent shadow_mode_toggled manual_halt_set manual_halt_cleared
    instrument_identity_fallback instrument_delisted instrument_relisted sync_gap_unrecoverable trade_reviewed account_configured
  ].freeze

  belongs_to :user, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  enum :actor, { human: "human", system: "system", agent: "agent" }, prefix: true

  validates :kind, inclusion: { in: KINDS }

  def self.log(kind, actor:, data: {}, user: nil, subject: nil, reason: nil)
    create!(kind: kind, actor: actor, user: user, subject: subject, reason: reason, data: data)
  end

  def readonly? = persisted?
end
