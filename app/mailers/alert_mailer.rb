# One email per event the operator must act on or know about, with the sentence Alert wrote for it (the push
# carries the same sentence). A desk with no users yet (the first boot, a test with none) has nobody to
# alert; the audit row still stands.
class AlertMailer < ApplicationMailer
  helper ApplicationHelper

  def unprotected_position(position, subject:)
    @position = position
    alert subject
  end

  def submission_unknown(proposal, subject:)
    @proposal = proposal
    alert subject
  end

  def new_proposal(proposal, subject:)
    @proposal = proposal
    alert subject
  end

  def fill_or_cancel(proposal, subject:)
    @proposal = proposal
    alert subject
  end

  def late_submission(proposal, subject:)
    @proposal = proposal
    alert subject
  end

  def halt_tripped(rule:, reason:, resets_at:, subject:)
    @rule, @reason, @resets_at = rule, reason, resets_at
    alert subject
  end

  private
    def alert(subject) = (mail to: recipients, subject: "Athayde Desk: #{subject}" if recipients.any?)
end
