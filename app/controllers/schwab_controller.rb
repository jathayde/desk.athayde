# The three-legged OAuth round trip. Both routes require login; an unauthenticated hit is sent to
# sign in without a return-to URL, so the authorization code never lands in the session.
class SchwabController < ApplicationController
  STATE_TTL = 15.minutes # a Schwab login with a slow SMS code takes a while from a phone

  before_action :require_fake_adapter, only: :fake_authorize

  def authorize
    # String keys: the session is JSON-serialized and comes back that way.
    session[:schwab_state] = { "value" => SecureRandom.hex(16), "at" => Time.current.to_i }
    redirect_to Schwab.oauth_client(wait: false).authorize_url(state: session[:schwab_state]["value"]), allow_other_host: true
  end

  def callback
    pending = session.delete(:schwab_state)
    return render :nothing_pending, status: :conflict unless pending && pending["at"] > STATE_TTL.ago.to_i
    return reject_with("State mismatch", data: { csrf: true }) unless ActiveSupport::SecurityUtils.secure_compare(pending["value"], params[:state].to_s)
    return reject_with("Schwab returned #{params[:error]}") if params[:error].present?

    SchwabToken::Reauth.complete!(params.expect(:code), user: Current.user)
    redirect_to schwab_connected_path
  rescue SchwabToken::Reauth::Failure, Schwab::Error => e
    reject_with(e.message)
  end

  def connected
    @token = SchwabToken.current
  end

  # Development and Playwright only: stands in for Schwab's hosted login.
  def fake_authorize
    code = params[:fail].present? ? "bad-code" : Schwab::FakeClient::FAKE_CODE
    redirect_to schwab_callback_path(code: code, state: params[:state])
  end

  private
    def reject_with(message, data: {})
      AuditEvent.log("re_auth_failed", actor: :human, user: Current.user, reason: message.truncate(200), data: data)
      @message = message
      render :failed, status: :unprocessable_content
    end

    # The authorize URL carries nothing secret, so the Sunday email's link can resume after sign-in; the
    # callback URL carries the single-use code and is never stored.
    def request_authentication
      session[:return_to_after_authenticating] = request.url if action_name == "authorize"
      redirect_to new_session_path, alert: "Sign in, then start the Schwab connection again."
    end

    def require_fake_adapter
      head :not_found unless Schwab.fake? && !Rails.env.production?
    end
end
