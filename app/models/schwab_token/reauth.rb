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
    # Defense in depth for an unverified state echo, and the consent screen: a later auth must cover at least one
    # known account and every account the journal depends on; a read-only account left unticked is audited, since
    # its feeds will now fail until the next re-auth.
    def verify_accounts!(access_token)
      known = Account.all.to_a
      return if known.empty?
      seen = Schwab.client(token: Schwab::BearerToken.new(access_token: access_token), wait: false).account_numbers
      missing = known.reject { |account| seen.include?(account.schwab_hash) }
      raise Failure, "That Schwab login does not include any known account" if missing.size == known.size
      if (trading = missing.select(&:trading_enabled?)).any?
        raise Failure, "That Schwab login left #{trading.map(&:label).to_sentence} unticked; the journal needs it. Start again and tick every account."
      end
      AuditEvent.log("re_auth_missing_accounts", actor: :human, user: @user, data: { accounts: missing.map(&:label) }) if missing.any?
    end
end
