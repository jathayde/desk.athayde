# The time-sensitive alerts (docs/phase-2-plan.md §0.14): one mail per event, no figures in subjects,
# template links only. Push replaces these when the iOS shell exists.
class AlertMailer < ApplicationMailer
  helper ApplicationHelper

  # A desk with no users yet (the first boot, a test with none) has nobody to alert; the audit row still stands.
  def unprotected_position(position)
    return if recipients.empty?
    @position = position
    mail to: recipients, subject: "Athayde Desk: #{position.instrument.symbol} is unprotected"
  end

  def submission_unknown(proposal)
    return if recipients.empty?
    @proposal = proposal
    mail to: recipients, subject: "Athayde Desk: a submission on #{proposal.instrument.symbol} is unresolved"
  end

  private
    def recipients = User.pluck(:email_address)
end
