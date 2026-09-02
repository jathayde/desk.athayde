class ApplicationMailer < ActionMailer::Base
  default from: "Athayde Desk <desk@athayde.com>"
  layout "mailer"

  private
    def recipients = User.notified.pluck(:email_address)
end
