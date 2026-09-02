# One email per event the operator must act on or know about, sent by the model that made the state, after it
# is committed. A desk with no users yet (the first boot, a test with none) has nobody to alert; the audit row
# still stands.
class AlertMailer < ApplicationMailer
  helper ApplicationHelper

  def unprotected_position(position)
    @position = position
    alert "#{position.instrument.symbol} is unprotected"
  end

  def submission_unknown(proposal)
    @proposal = proposal
    alert "a submission on #{proposal.instrument.symbol} is unresolved"
  end

  # The agent proposed something: the operator hears about it once, whatever the rules said.
  def new_proposal(proposal)
    @proposal = proposal
    alert "#{proposal.label} #{proposal.status_label}"
  end

  def fill_or_cancel(proposal)
    @proposal = proposal
    alert "#{proposal.label} #{proposal.status}"
  end

  # Schwab answered with an id after the reconcile job had called the order not placed: the operator was told
  # nothing was working, and now something is.
  def late_submission(proposal)
    @proposal = proposal
    alert "#{proposal.label} is working at Schwab after all"
  end

  def halt_tripped(rule:, reason:, resets_at:)
    @rule, @reason, @resets_at = rule, reason, resets_at
    alert "entries halted by #{rule.humanize.downcase}"
  end

  private
    def alert(subject) = (mail to: recipients, subject: "Athayde Desk: #{subject}" if recipients.any?)
end
