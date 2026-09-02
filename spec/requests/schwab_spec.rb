require "rails_helper"

RSpec.describe "Schwab re-auth" do
  let(:user) { create(:user, email_address: "john@athayde.com") }
  let(:fake) { Schwab::FakeClient.instance }

  def start_authorize
    get schwab_authorize_path
    expect(response).to redirect_to(%r{/schwab/fake_authorize\?state=})
    Rack::Utils.parse_query(URI(response.location).query)["state"]
  end

  it "requires login and never stores the callback as a return-to URL, but resumes authorize after sign-in" do
    get schwab_callback_path(code: "x", state: "y")
    expect(response).to redirect_to(new_session_path)
    expect(session[:return_to_after_authenticating]).to be_nil
    get schwab_authorize_path
    expect(response).to redirect_to(new_session_path)
    expect(session[:return_to_after_authenticating]).to end_with("/schwab/authorize")
  end

  context "signed in" do
    before { sign_in user }

    it "completes the round trip through the fake authorize page, redirects to a clean page, audits, and enqueues catch-up" do
      state = start_authorize
      expect {
        get schwab_fake_authorize_path(state: state)
        follow_redirect!
      }.to have_enqueued_job(Sync::CatchUpJob)
      expect(response).to redirect_to(schwab_connected_path)
      follow_redirect!
      expect(response.body).to include("Schwab connected")
      expect(SchwabToken.current).to be_usable
      expect(AuditEvent.where(kind: "re_auth_succeeded").last.user).to eq(user)
    end

    it "clears a pause and audits the resumption on success" do
      SystemSettings.instance.update!(sync_paused_reason: "expired")
      state = start_authorize
      get schwab_callback_path(code: Schwab::FakeClient::FAKE_CODE, state: state)
      expect(SystemSettings.instance.sync_paused_reason).to be_nil
      expect(AuditEvent.where(kind: "sync_resumed")).to exist
    end

    it "renders nothing-pending, without an audit, when no state is pending" do
      get schwab_callback_path(code: "x", state: "y")
      expect(response).to have_http_status(:conflict)
      expect(response.body).to include("Nothing pending")
      expect(AuditEvent.where(kind: "re_auth_failed")).not_to exist
    end

    it "renders nothing-pending on a second hit of the same link, issuing no second token" do
      state = start_authorize
      get schwab_callback_path(code: Schwab::FakeClient::FAKE_CODE, state: state)
      get schwab_callback_path(code: Schwab::FakeClient::FAKE_CODE, state: state)
      expect(response).to have_http_status(:conflict)
      expect(AuditEvent.where(kind: "re_auth_failed")).not_to exist
      expect(SchwabToken.count).to eq(1)
    end

    it "returns 400 for a callback with neither code nor error" do
      state = start_authorize
      get schwab_callback_path(state: state)
      expect(response).to have_http_status(:bad_request)
      expect(AuditEvent.where(kind: "re_auth_failed")).not_to exist
    end

    it "rejects a stale state" do
      state = start_authorize
      travel SchwabController::STATE_TTL + 1.minute
      get schwab_callback_path(code: Schwab::FakeClient::FAKE_CODE, state: state)
      expect(response).to have_http_status(:conflict)
    end

    it "treats a state mismatch as CSRF and audits it" do
      start_authorize
      get schwab_callback_path(code: Schwab::FakeClient::FAKE_CODE, state: "forged")
      expect(response).to have_http_status(:unprocessable_content)
      expect(AuditEvent.where(kind: "re_auth_failed").last.data).to eq("csrf" => true)
      expect(SchwabToken.count).to eq(0)
    end

    it "shows a failure with a retry link when the exchange fails, leaving the old token alone" do
      old = create(:schwab_token)
      state = start_authorize
      get schwab_fake_authorize_path(state: state, fail: 1)
      follow_redirect!
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Try again").and include(schwab_authorize_path)
      expect(SchwabToken.current).to eq(old)
      expect(AuditEvent.where(kind: "re_auth_failed")).to exist
    end

    it "handles the user cancelling at Schwab without calling the token endpoint" do
      state = start_authorize
      get schwab_callback_path(error: "access_denied", state: state)
      expect(response).to have_http_status(:unprocessable_content)
      expect(fake.calls.map(&:first)).not_to include(:exchange_code)
    end

    it "refuses a login for accounts it does not know" do
      create(:account, schwab_hash: "F" * 64)
      state = start_authorize
      get schwab_callback_path(code: Schwab::FakeClient::FAKE_CODE, state: state)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("does not include any known account")
      expect(SchwabToken.count).to eq(0)
    end

    it "accepts a login that covers a known account" do
      create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH)
      state = start_authorize
      get schwab_callback_path(code: Schwab::FakeClient::FAKE_CODE, state: state)
      expect(response).to redirect_to(schwab_connected_path)
    end

    context "with the real adapter and no token at all" do
      before { allow(Rails.configuration.x.schwab).to receive(:adapter).and_return(:http) }

      it "still starts the round trip and completes it against the token endpoint" do
        get schwab_authorize_path
        expect(response.location).to start_with("https://api.schwabapi.com/v1/oauth/authorize?")
        state = Rack::Utils.parse_query(URI(response.location).query)["state"]
        exchange = stub_request(:post, "https://api.schwabapi.com/v1/oauth/token")
          .with(body: hash_including(grant_type: "authorization_code", code: "real-code@"))
          .to_return(status: 200, body: schwab_fixture("token").to_json)
        get schwab_callback_path(code: "real-code@", state: state)
        expect(exchange).to have_been_requested
        expect(response).to redirect_to(schwab_connected_path)
        expect(SchwabToken.current).to be_usable
      end
    end

    it "hides the fake authorize page outside the fake adapter" do
      allow(Rails.configuration.x.schwab).to receive(:adapter).and_return(:http)
      get schwab_fake_authorize_path(state: "s")
      expect(response).to have_http_status(:not_found)
    end
  end
end
