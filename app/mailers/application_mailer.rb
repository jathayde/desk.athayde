class ApplicationMailer < ActionMailer::Base
  default from: "Athayde Desk <desk@athayde.com>"
  layout "mailer"

  private
    def recipients = User.pluck(:email_address)
end
