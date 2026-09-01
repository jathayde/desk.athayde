require "rails_helper"

RSpec.describe Schwab do
  context "with the real adapter" do
    before { allow(Rails.configuration.x.schwab).to receive(:adapter).and_return(:http) }

    it "refuses to build a data client without a usable token" do
      expect { Schwab.client }.to raise_error(Schwab::NoUsableToken)
      create(:schwab_token, :revoked)
      expect { Schwab.client }.to raise_error(Schwab::NoUsableToken)
    end

    it "builds a data client from the current usable token, or from a bearer handed in" do
      create(:schwab_token)
      expect(Schwab.client).to be_a(Schwab::Client)
      expect(Schwab.client(token: Schwab::BearerToken.new(access_token: "x"))).to be_a(Schwab::Client)
    end

    it "builds the OAuth client with no token at all, which is when re-auth happens" do
      expect(Schwab.oauth_client.authorize_url(state: "s")).to start_with("https://api.schwabapi.com/v1/oauth/authorize")
    end
  end

  it "returns the fake for everything outside production" do
    expect(Schwab.client).to be(Schwab::FakeClient.instance)
    expect(Schwab.oauth_client).to be(Schwab::FakeClient.instance)
  end
end
