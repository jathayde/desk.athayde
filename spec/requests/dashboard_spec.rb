require "rails_helper"

RSpec.describe "Dashboard" do
  it "requires sign-in" do
    get root_path
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    let(:account) { create(:account, trading_enabled: true) }
    before { sign_in create(:user) }

    it "shows the connect call to action before any token exists" do
      get root_path
      expect(response.body).to include("Connect Schwab").and include(schwab_authorize_path)
      expect(response.body).not_to include("banner")
    end

    it "shows the setup call to action when accounts synced but none trades" do
      create(:schwab_token)
      create(:account, account_type: nil, trading_enabled: false)
      get root_path
      expect(response.body).to include("Set up the trading account")
    end

    it "renders the glance with positions, risk, cash, review count, and as-of stamps" do
      create(:schwab_token)
      create(:balance, account: account, equity: 10_240, settled_cash: 2_110, unsettled_cash: 980, as_of: 2.minutes.ago)
      xyz = create(:instrument, symbol: "XYZ")
      create(:position, account: account, instrument: xyz, quantity: 40, last_price: 53, average_price: 51.18, market_value: 2120, cost_basis: 2047.2,
                        working_stop_order: create(:order, :working_stop, account: account, instrument: xyz, stop_price: 48.9))
      create(:trade, account: account, instrument: xyz, needs_review: true, review_reason: "missing_setup")
      create(:sync_run, feed: "orders", account: account, status: "succeeded", finished_at: 1.minute.ago)
      get root_path
      expect(response.body).to include("$10,240.00").and include("$2,110.00 / $980.00").and include("XYZ").and include("7.7% to stop").and include("1 trade needs review").and include("first snapshot after today")
      expect(response.body).to include("none waiting")
      create(:order_proposal, account: account, instrument: xyz, status: "validated")
      create(:order_proposal, account: account, instrument: xyz, status: "proposed", side: "sell", kind: "exit", stop_price: nil)
      create(:order_proposal, account: account, instrument: create(:instrument, symbol: "DEF"), status: "submitted", shadow: true)
      get root_path
      expect(response.body).to include("2 waiting and 1 to place by hand")
    end

    it "shows no connection status line on the connect state" do
      get root_path
      expect(response.body).to include("Connect Schwab")
      expect(response.body).not_to include("status-line")
    end

    { revoked: -> { create(:schwab_token, :revoked, last_refresh_error: "invalid_grant") },
      expired: -> { create(:schwab_token, issued_at: 8.days.ago); create(:sync_run, feed: "positions", status: "skipped_token", started_at: 1.hour.ago) },
      expiring: -> { create(:schwab_token, issued_at: 6.days.ago - 2.hours) } }.each do |state, setup|
      it "renders only the #{state} banner" do
        create(:balance, account: account, equity: 10_000, as_of: Time.current)
        instance_exec(&setup)
        get root_path
        expect(response.body.scan(/class="banner/).size).to eq(1)
        expect(response.body).to include("banner #{state == :revoked ? 'expired' : state}")
      end
    end

    it "keeps the token status line under a halt banner" do
      create(:balance, account: account, equity: 10_000, as_of: Time.current)
      create(:schwab_token, issued_at: 6.days.ago - 2.hours)
      SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "bad day")
      get root_path
      expect(response.body).to include("Halted").and include("bad day").and include("status-line").and include("Token expires")
      expect(response.body.scan(/class="banner/).size).to eq(1)
    end

    it "shows the no-positions and unavailable-cash states" do
      create(:schwab_token)
      create(:balance, account: account, equity: 10_000, settled_cash: nil, unsettled_cash: nil, as_of: Time.current)
      get root_path
      expect(response.body).to include("No open positions").and include("unavailable / unavailable")
    end
  end
end
