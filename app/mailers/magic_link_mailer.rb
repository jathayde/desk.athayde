class MagicLinkMailer < ApplicationMailer
  def sign_in(user)
    @user = user
    @url = magic_link_url(token: user.magic_link_token)
    mail to: user.email_address, subject: "Your Athayde Desk sign-in link"
  end
end
