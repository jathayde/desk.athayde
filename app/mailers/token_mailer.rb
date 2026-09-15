class TokenMailer < ApplicationMailer
  def nag(reason, token)
    @reason, @token = reason, token
    @reauth_url = schwab_authorize_url
    mail to: recipients, subject: t(".subject.#{reason}")
  end
end
