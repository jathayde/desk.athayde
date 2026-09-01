class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    User.find_by(email_address: params.expect(:email_address))&.send_magic_link
    redirect_to new_session_path, notice: "If that address has access, a sign-in link is on its way."
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
