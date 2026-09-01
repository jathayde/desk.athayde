# The emailed URL lands on a page with no side effects, so mail scanners and link previews
# cannot consume the link. Only the POST from that page signs the user in.
class MagicLinksController < ApplicationController
  allow_unauthenticated_access

  def show
    @token = params.expect(:token)
  end

  def create
    if user = User.consume_magic_link(params.expect(:token))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "That sign-in link is invalid or has expired. Request a new one."
    end
  end
end
