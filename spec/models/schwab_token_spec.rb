require "rails_helper"

RSpec.describe SchwabToken do
  let(:token_response) { { "access_token" => "acc-1", "refresh_token" => "ref-1", "expires_in" => 1800, "scope" => "api" } }
  let(:fake) { Schwab::FakeClient.instance }

  it "encrypts tokens at rest" do
    token = create(:schwab_token, access_token: "access-abc", refresh_token: "refresh-xyz")
    stored = SchwabToken.lease_connection.select_one(SchwabToken.sanitize_sql([ "SELECT access_token, refresh_token FROM schwab_tokens WHERE id = ?", token.id ]))
    expect(stored["access_token"]).not_to eq("access-abc")
    expect(stored["refresh_token"]).not_to eq("refresh-xyz")
    expect(token.reload).to have_attributes(access_token: "access-abc", refresh_token: "refresh-xyz")
  end

  describe ".issue!" do
    it "creates the current token with a 168-hour refresh life and a margin on the access token" do
      now = Time.zone.parse("2026-09-06 18:30 EDT")
      travel_to now # usable? reads the clock; issued at a pinned time, it must be judged at that time
      token = SchwabToken.issue!(token_response, now: now)
      expect(token).to be_current.and be_usable
      expect(token.refresh_expires_at).to eq(now + 168.hours)
      expect(token.access_expires_at).to eq(now + 29.minutes)
    end

    it "clears a pause, audits the resumption, and enqueues catch-up" do
      SystemSettings.instance.update!(sync_paused_reason: "expired")
      expect { SchwabToken.issue!(token_response) }.to have_enqueued_job(Sync::CatchUpJob)
      expect(SystemSettings.instance.sync_paused_reason).to be_nil
      expect(AuditEvent.where(kind: "sync_resumed")).to exist
    end

    it "does not audit a resumption when nothing was paused" do
      SchwabToken.issue!(token_response)
      expect(AuditEvent.where(kind: "sync_resumed")).not_to exist
    end
  end

  describe "usability over time" do
    it "expires the refresh token 7 elapsed days after issuance" do
      token = create(:schwab_token)
      travel 6.days + 23.hours
      expect(token).to be_usable.and be_refresh_expiring_soon
      travel 2.hours
      expect(token).not_to be_usable
      expect(token).to be_refresh_expired
    end

    it "is unusable once revoked" do
      expect(create(:schwab_token, :revoked)).not_to be_usable
    end

    it "reports the newest row as current" do
      old = create(:schwab_token, issued_at: 2.days.ago)
      new = create(:schwab_token)
      expect(SchwabToken.current).to eq(new)
      expect(old).not_to be_current
    end
  end

  describe "#refresh!" do
    let(:token) { create(:schwab_token, access_expires_at: 1.minute.from_now) }

    it "rotates the access token, keeps the refresh expiry, and stores the returned refresh token" do
      fake.enqueue(:refresh) { { "access_token" => "acc-2", "refresh_token" => "ref-2", "expires_in" => 1800 } }
      original_expiry = token.refresh_expires_at
      token.refresh!
      expect(token.reload).to have_attributes(access_token: "acc-2", refresh_token: "ref-2", refresh_expires_at: original_expiry, last_refresh_error: nil)
      expect(token.access_expires_at).to be_within(2.seconds).of(29.minutes.from_now)
      expect(token.last_refreshed_at).to be_present
    end

    it "keeps the existing refresh token when the response omits one" do
      fake.enqueue(:refresh) { { "access_token" => "acc-2", "expires_in" => 1800 } }
      original = token.refresh_token
      token.refresh!
      expect(token.reload.refresh_token).to eq(original)
    end

    it "records a malformed token response as a mapping error" do
      fake.enqueue(:refresh) { { "expires_in" => 1800 } }
      expect { token.refresh! }.to raise_error(Schwab::MappingError)
      expect(token.reload.last_refresh_error).to include("access_token")
      expect(token).not_to be_revoked
    end

    it "debounces: a second holder of the same row within a minute sees the rotated token and does not call Schwab" do
      fake.enqueue(:refresh) { { "access_token" => "acc-2", "refresh_token" => "ref-2", "expires_in" => 1800 } }
      first, second = SchwabToken.find(token.id), SchwabToken.find(token.id)
      first.refresh!
      second.refresh!
      expect(fake.calls.map(&:first)).to eq([ :refresh ])
      expect(second.access_token).to eq("acc-2")
    end

    it "does nothing on a row that is no longer current" do
      stale = token
      create(:schwab_token)
      stale.refresh!
      expect(fake.calls).to be_empty
    end

    it "revokes the current token, pauses sync, and audits when Schwab rejects the grant" do
      fake.enqueue(:refresh) { raise Schwab::ReauthRequired.new("invalid_grant", status: 400) }
      expect { token.refresh! }.to raise_error(Schwab::ReauthRequired)
      expect(token.reload).to be_revoked
      expect(token.last_refresh_error).to include("invalid_grant")
      expect(SystemSettings.instance.sync_paused_reason).to eq(SchwabToken::PAUSE_REASON)
      expect(AuditEvent.where(kind: "token_refresh_failed", subject: token)).to exist
      expect(SchwabToken.usable?).to be(false)
    end

    it "records a server error without revoking or pausing" do
      fake.enqueue(:refresh) { raise Schwab::ServerError.new("503", status: 503) }
      expect { token.refresh! }.to raise_error(Schwab::ServerError)
      expect(token.reload).not_to be_revoked
      expect(token.last_refresh_error).to include("503")
      expect(SystemSettings.instance.sync_paused_reason).to be_nil
    end

    it "cannot pause sync when superseded during the call" do
      superseded = token
      allow(superseded).to receive(:current?).and_return(true, false) # the callback lands while this refresh is in flight
      fake.enqueue(:refresh) { raise Schwab::ReauthRequired.new("invalid_grant", status: 400) }
      expect { superseded.refresh! }.to raise_error(Schwab::ReauthRequired)
      expect(superseded.reload).not_to be_revoked
      expect(superseded.last_refresh_error).to include("invalid_grant")
      expect(SystemSettings.instance.sync_paused_reason).to be_nil
      expect(AuditEvent.where(kind: "token_refresh_failed")).not_to exist
    end

    it "passes the caller's wait mode through to the OAuth client" do
      allow(Schwab).to receive(:oauth_client).and_call_original
      token.refresh!(wait: false)
      expect(Schwab).to have_received(:oauth_client).with(wait: false)
    end
  end

  describe "#ensure_fresh!" do
    it "refreshes only when the access token is near expiry" do
      create(:schwab_token, access_expires_at: 20.minutes.from_now).ensure_fresh!
      expect(fake.calls).to be_empty
      create(:schwab_token, access_expires_at: 2.minutes.from_now).ensure_fresh!
      expect(fake.calls.map(&:first)).to eq([ :refresh ])
    end
  end
end
