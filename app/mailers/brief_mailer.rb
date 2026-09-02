# Every scheduled email. Subjects carry no dollar figures; every link is generated here, never by the model.
class BriefMailer < ApplicationMailer
  helper ApplicationHelper

  def brief(run)
    @brief = Brief.new(run)
    @run = run
    mail to: recipients, subject: @brief.subject
  end

  def sunday_review(run)
    @run = run
    @status = SystemStatus.new
    @setups = Setup.order(:name)
    @reauth_url = schwab_authorize_url
    mail to: recipients, subject: "Athayde Desk: Sunday review, re-authenticate Schwab"
  end

  def failure_digest(digest)
    @digest = digest
    mail to: recipients, subject: "Athayde Desk: failures in the last 24 hours"
  end

  private
    def recipients = User.pluck(:email_address)
end
