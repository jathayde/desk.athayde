class ApplicationMailer < ActionMailer::Base
  default from: "Athayde Desk <desk@athayde.com>"
  layout "mailer"

  private
    # Desk email reaches the approver and no one else, whatever notify says for another reader: a second reader is
    # never mailed. The sign-in link is the exception, sent only to whoever asked for it.
    def recipients = User.notified.where(approver: true).pluck(:email_address)
end
