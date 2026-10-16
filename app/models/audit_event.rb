# Append-only. Every "logged" action in the PRD is a row here; the database triggers reject
# UPDATE, DELETE, and TRUNCATE, and Active Record refuses updates before it gets that far.
class AuditEvent < ApplicationRecord
  KINDS = %w[
    re_auth_succeeded re_auth_failed re_auth_missing_accounts token_refresh_failed sync_paused_token_expired sync_resumed
    token_nag_sent shadow_mode_toggled manual_halt_set manual_halt_cleared device_registered device_removed
    instrument_identity_fallback instrument_delisted instrument_relisted sync_gap_unrecoverable activity_type_skipped trade_reviewed account_configured
    proposal_created proposal_evaluated proposal_approved proposal_approval_refused proposal_rejected proposal_submitting proposal_submitted
    would_have_submitted submission_unknown submission_reconciled submission_failed submission_skipped submission_answer_ignored proposal_expired proposal_filled
    proposal_cancelled stop_adjusted trade_annotated watchlist_changed rule_changed rule_halt_tripped rule_halt_cleared unprotected_alert_sent agent_tool_used
    deployment_policy_changed allocation_target_changed instrument_classified instrument_tagged allocation_drift_recorded allocation_drift_checked
    thesis_review_created thesis_review_decided
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
