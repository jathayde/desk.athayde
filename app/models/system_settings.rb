# One row, enforced by a check constraint on id = 1. Holds the global flags the PRD calls out:
# shadow mode (on by default), the manual halt, and why sync is paused.
class SystemSettings < ApplicationRecord
  # Two halts (docs/phase-2-plan.md §0.3): the kill switch stops everything; a rule halt (daily loss, drawdown)
  # blocks new entries only, so exits and tighten-only stop adjustments stay available. Shadow mode is not a
  # gate: it is the branch between "would have submitted" and a real call.
  LIVE_CONFIRMATION, SHADOW_CONFIRMATION = "go live", "shadow"

  def halted? = manual_halt? || rule_halted?
  def entries_allowed? = !halted?
  def exits_allowed? = !manual_halt?
  def rule_halted? = rule_halt_tripped_at.present? && (rule_halt_resets_at.nil? || rule_halt_resets_at > Time.current)

  # Under the row lock, since two evaluators can trip at once. A second rule tripping during a halt extends
  # it to the later reset and records the rule; a lapsed halt is cleared with its own audit row by the tick.
  def trip_rule_halt!(rule:, reason:, resets_at:)
    with_lock do
      extending = rule_halted?
      next if extending && !extends_halt?(resets_at)
      update!(rule_halt_rule: rule, rule_halt_reason: reason, rule_halt_resets_at: resets_at, rule_halt_tripped_at: extending ? rule_halt_tripped_at : Time.current)
      AuditEvent.log("rule_halt_tripped", actor: :system, reason: reason, data: { rule: rule, resets_at: resets_at, extended: extending })
      # The evaluator trips halts inside the proposal's transaction: the mail waits for the outermost commit,
      # so a rolled-back evaluation sends nothing about a halt that never happened.
      ActiveRecord.after_all_transactions_commit { AlertMailer.halt_tripped(rule: rule, reason: reason, resets_at: resets_at).deliver_later }
    end
    self
  end

  def clear_rule_halt!(user: nil, reason: nil)
    with_lock do
      next unless rule_halt_tripped_at
      AuditEvent.log("rule_halt_cleared", actor: user ? :human : :system, user: user, reason: reason, data: { rule: rule_halt_rule })
      update!(rule_halt_rule: nil, rule_halt_reason: nil, rule_halt_tripped_at: nil, rule_halt_resets_at: nil)
    end
    self
  end

  class Unconfirmed < StandardError; end

  # Shadow mode off means the next approve reaches Schwab; on is the same gesture in reverse. Audited both ways
  # with the shadow evidence that justified it. The typed word is checked under the row lock, so two "go live"
  # posts crossing cannot have the second one flip the desk straight back to shadow.
  def toggle_shadow_mode!(user:, reason:, confirmation:)
    with_lock do
      raise Unconfirmed, "Type #{confirmation_word} to confirm." unless confirmation.to_s.strip.casecmp?(confirmation_word)
      status = SystemStatus.new
      update!(shadow_mode: !shadow_mode?, shadow_mode_changed_at: Time.current)
      AuditEvent.log("shadow_mode_toggled", actor: :human, user: user, reason: reason,
                     data: { shadow_mode: shadow_mode, shadowed_approvals: status.shadowed_approvals, shadow_reconciled: status.shadow_reconciled })
    end
    self
  end

  def confirmation_word = shadow_mode? ? LIVE_CONFIRMATION : SHADOW_CONFIRMATION

  def sweep_rule_halt!
    clear_rule_halt!(reason: "reset time passed") if rule_halt_tripped_at && !rule_halted?
  end

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

  private
    # nil means until cleared by hand, later than any time; only a strictly later reset changes anything, so a
    # rule re-evaluated during its own halt writes nothing.
    def extends_halt?(resets_at) = rule_halt_resets_at.present? && (resets_at.nil? || resets_at > rule_halt_resets_at)
end
