require "rails_helper"

RSpec.describe Desk do
  let(:account) { create(:account, trading_enabled: true) }

  describe "#state" do
    it "is not connected without a token" do
      expect(Desk.new.state).to eq(:not_connected)
    end

    it "waits for accounts, then setup, then the first sync, then is ready" do
      create(:schwab_token)
      expect(Desk.new.state).to eq(:waiting_for_accounts)
      create(:account, account_type: nil, trading_enabled: false)
      expect(Desk.new.state).to eq(:needs_setup)
      account
      expect(Desk.new.state).to eq(:waiting_first_sync)
      create(:balance, account: account, equity: 10_000, as_of: Time.current)
      expect(Desk.new.state).to eq(:ready)
    end
  end

  describe "#banner" do
    it "puts a halt first and carries the token problem as a status line" do
      create(:schwab_token, :revoked)
      SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "testing")
      d = Desk.new
      expect(d.banner).to eq(:halted)
      expect(d.secondary_statuses).to include(:revoked)
    end

    it "shows revoked, expired, and expiring in that order of seriousness" do
      create(:schwab_token, :revoked)
      expect(Desk.new.banner).to eq(:revoked)
      SchwabToken.delete_all
      create(:schwab_token, issued_at: 8.days.ago)
      expect(Desk.new.banner).to eq(:expired)
      SchwabToken.delete_all
      create(:schwab_token, issued_at: 6.days.ago - 2.hours)
      expect(Desk.new.banner).to eq(:expiring)
    end

    it "puts an unprotected position above the expiry nag" do
      account = create(:account, trading_enabled: true)
      create(:schwab_token, issued_at: 6.days.ago - 2.hours)
      create(:balance, account: account, as_of: Time.current)
      create(:position, account: account, instrument: create(:instrument, symbol: "XYZ"), working_stop_order: nil)
      desk = Desk.new
      expect(desk.banner).to eq(:unprotected)
      expect(desk.secondary_statuses).to include(:expiring)
    end

    it "puts an unknown submission on this account above a dead token, and ignores another account's" do
      account = create(:account, trading_enabled: true)
      create(:schwab_token, issued_at: 8.days.ago)
      create(:balance, account: account, as_of: Time.current)
      xyz = create(:instrument, symbol: "XYZ")
      create(:order_proposal, account: create(:account, account_type: "ira", trading_enabled: false), instrument: xyz, status: "submission_unknown")
      expect(Desk.new.banner).to eq(:expired)
      create(:order_proposal, account: account, instrument: xyz, status: "submission_unknown")
      desk = Desk.new
      expect(desk.banner).to eq(:submission_unknown)
      expect(desk.secondary_statuses).to include(:expired)
    end

    it "carries a rule halt as a status line and never a missing token on the connect state" do
      expect(Desk.new.secondary_statuses).to be_empty
      SystemSettings.instance.trip_rule_halt!(rule: "daily_loss_halt", reason: "down", resets_at: 1.hour.from_now)
      expect(Desk.new.secondary_statuses).to eq([ :rule_halted ])
    end

    it "has no banner without a token; the connect state carries it" do
      expect(Desk.new.banner).to be_nil
    end
  end

  describe "#secondary_statuses" do
    before { create(:schwab_token); create(:balance, account: account, equity: 10_000, as_of: Time.current) }

    it "reports a pause for a non-token reason and a fallback calendar" do
      SystemSettings.instance.update!(sync_paused_reason: "operator")
      MarketDay.for(MarketDay.today).update!(source: :fallback)
      expect(Desk.new.secondary_statuses).to include(:sync_paused, :calendar_fallback)
    end

    it "reports a failed sync only until something succeeds after it, including on a feed that never succeeded" do
      create(:sync_run, feed: "orders", account: account, status: "failed", error: "503", started_at: 5.minutes.ago)
      expect(Desk.new.sync_failure.error).to eq("503")
      create(:sync_run, feed: "orders", account: account, status: "succeeded", started_at: 1.minute.ago, finished_at: 1.minute.ago)
      expect(Desk.new.sync_failure).to be_nil
    end
  end

  it "counts this account's waiting proposals and hand placements" do
    account = create(:account, trading_enabled: true)
    create(:order_proposal, account: account, instrument: create(:instrument, symbol: "XYZ"), status: "validated")
    create(:order_proposal, account: account, instrument: create(:instrument, symbol: "DEF"), status: "submitted", shadow: true)
    create(:order_proposal, account: create(:account, account_type: "ira", trading_enabled: false), instrument: create(:instrument, symbol: "IRA"), status: "validated")
    expect(Desk.new).to have_attributes(pending_proposal_count: 1, hand_placement_count: 1)
  end

  it "computes the flow-adjusted day change against the prior snapshot by date" do
    create(:schwab_token)
    create(:balance, account: account, equity: 12_000, as_of: Time.current)
    create(:snapshot, account: account, as_of: MarketDay.today - 3, equity: 10_000)
    create(:snapshot, account: account, as_of: MarketDay.today, equity: 11_500) # today's exists but is not the prior
    flow(account, "deposit", 1_000, on: MarketDay.today)
    d = Desk.new
    expect(d.prior_snapshot.as_of).to eq(MarketDay.today - 3)
    expect(d.day_change).to eq(1_000)
    expect(d.day_change_ratio).to eq(BigDecimal("0.1"))
  end

  it "sorts unprotected first, then by distance, links each row to its trade, and marks stale rows" do
    create(:schwab_token)
    create(:balance, account: account, equity: 10_000, as_of: Time.current)
    near = create(:instrument, symbol: "NEAR"); far = create(:instrument, symbol: "FAR"); bare = create(:instrument, symbol: "BARE")
    create(:position, account: account, instrument: far, quantity: 40, last_price: 60, working_stop_order: create(:order, :working_stop, account: account, instrument: far, stop_price: 48))
    create(:position, account: account, instrument: near, quantity: 40, last_price: 50, working_stop_order: create(:order, :working_stop, account: account, instrument: near, stop_price: 48.9), synced_at: 5.hours.ago)
    create(:position, account: account, instrument: bare, quantity: 10, last_price: 20)
    trade = create(:trade, account: account, instrument: near)
    create(:sync_run, feed: "orders", account: account, status: "succeeded", finished_at: 1.minute.ago)
    d = Desk.new
    expect(d.rows.map { |r| r.position.instrument.symbol }).to eq(%w[ BARE NEAR FAR ])
    expect(d.rows.map(&:stale)).to eq([ false, true, false ])
    expect(d.rows.find { |r| r.position.instrument == near }.trade).to eq(trade)
    expect(d.excluded_by_reason).to eq(unprotected: 1)
    expect(d.open_risk).to eq(40 * BigDecimal("1.1") + 40 * 12)
  end

  it "judges a stop-bearing row by the orders cadence too" do
    create(:schwab_token)
    create(:balance, account: account, equity: 10_000, as_of: Time.current)
    xyz = create(:instrument)
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 53, working_stop_order: create(:order, :working_stop, account: account, instrument: xyz), synced_at: Time.current)
    expect(Desk.new.rows.sole.stale).to be(true) # no orders run has ever finished
    create(:sync_run, feed: "orders", account: account, status: "succeeded", finished_at: 3.hours.ago)
    expect(Desk.new.rows.sole.stale).to be(true)
    create(:sync_run, feed: "orders", account: account, status: "succeeded", finished_at: 1.minute.ago)
    expect(Desk.new.rows.sole.stale).to be(false)
  end

  it "treats everything as stale while sync is paused, and dates the pause from the current token" do
    create(:sync_run, feed: "positions", status: "skipped_token", started_at: 30.days.ago)
    token = create(:schwab_token, :revoked, issued_at: 2.days.ago)
    create(:sync_run, feed: "positions", status: "skipped_token", started_at: 1.hour.ago)
    create(:balance, account: account, equity: 10_000, as_of: Time.current)
    SystemSettings.instance.update!(sync_paused_reason: "expired")
    d = Desk.new
    expect(d.balance_stale?).to be(true)
    expect(d.sync_paused_since).to be_within(1.second).of(1.hour.ago)
  end

  it "never calls Schwab while rendering, even with a fallback calendar" do
    create(:schwab_token)
    create(:balance, account: account, equity: 10_000, as_of: Time.current)
    create(:position, account: account, instrument: create(:instrument), quantity: 10, last_price: 20)
    MarketDay.for(MarketDay.today).update!(source: :fallback)
    Schwab::FakeClient.instance.reset!
    d = Desk.new
    d.rows; d.secondary_statuses; d.balance_stale?
    expect(Schwab::FakeClient.instance.calls).to be_empty
  end
end
