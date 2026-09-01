require "rails_helper"

RSpec.describe Schwab::RefreshAccessTokenJob do
  it "refreshes the current usable token and no-ops otherwise" do
    described_class.perform_now
    expect(Schwab::FakeClient.instance.calls).to be_empty
    create(:schwab_token, :revoked)
    described_class.perform_now
    expect(Schwab::FakeClient.instance.calls).to be_empty
    token = create(:schwab_token)
    described_class.perform_now
    expect(Schwab::FakeClient.instance.calls.map(&:first)).to eq([ :refresh ])
    expect(token.reload.last_refreshed_at).to be_present
  end

  it "swallows Schwab errors after the token has recorded them" do
    create(:schwab_token)
    Schwab::FakeClient.instance.enqueue(:refresh) { raise Schwab::ServerError.new("down", status: 503) }
    expect { described_class.perform_now }.not_to raise_error
    expect(SchwabToken.current.last_refresh_error).to include("down")
  end
end
