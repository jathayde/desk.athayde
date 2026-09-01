# One re-auth: exchange the code, make sure the login is for the accounts we know, then issue the token.
# Nothing is written until the last step, so a failure leaves the previous token untouched.
class SchwabToken::Reauth
  class Failure < StandardError; end

  def self.complete!(code, user:) = new(code, user: user).complete!

  def initialize(code, user:)
    @code, @user = code, user
  end

  def complete!
    response = Schwab.oauth_client(wait: false).exchange_code(@code)
    verify_accounts!(response.fetch("access_token"))
    SchwabToken.issue!(response).tap do |token|
      AuditEvent.log("re_auth_succeeded", actor: :human, user: @user, subject: token, data: { refresh_expires_at: token.refresh_expires_at })
    end
  end

  private
    # Defense in depth for an unverified state echo: a later auth must be for at least one known account.
    def verify_accounts!(access_token)
      known = Account.pluck(:schwab_hash)
      return if known.empty?
      seen = Schwab.client(token: Schwab::BearerToken.new(access_token: access_token), wait: false).account_numbers
      raise Failure, "That Schwab login does not include any known account" if (known & seen).empty?
    end
end
