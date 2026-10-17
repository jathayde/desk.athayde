require "rails_helper"

RSpec.describe Research::Features do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  before { ready_desk(account) }

  def propose = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, target_price: 56, thesis: "t", origin: :human, user: john)

  it "freezes what the desk saw on an entry, from final candles, with its version and what the history could not support" do
    proposal = propose
    features = proposal.reload.features
    expect(features).to include("version" => 1, "bars_through" => (MarketDay.today - 1).iso8601, "spy_bars_through" => (MarketDay.today - 1).iso8601)
    expect(features["values"].keys).to include("atr14_ratio", "close_vs_sma20", "close_vs_sma50", "volume_vs_avg20", "open_risk_ratio")
    expect(features["missing"]).to include("close_vs_sma200" => "59 final candles; 200 needed", "return63_less_spy" => "59 shared sessions; 64 needed")
    expect(features["values"]["atr14_ratio"]).to be_between(0.01, 0.1)
    expect { OrderProposal.transaction(requires_new: true) { proposal.update_columns(features: {}) } }.to raise_error(ActiveRecord::StatementInvalid, /written with it, never after/)
    create(:position, account: account, instrument: xyz, quantity: 10)
    proposal.reject!(user: john, reason: "no")
    exit = Proposals::Create.call(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 55, origin: :human, user: john)
    expect(exit.features).to be_nil
    expect { exit.update_columns(features: { "version" => 1 }) }.to raise_error(ActiveRecord::StatementInvalid, /never after/) # never backfilled
  end

  it "leaves every market feature missing on a stale or failed history, and never refuses the proposal" do
    Schwab::FakeClient.instance.reset!
    Rails.cache.clear
    proposal = Proposals.draft(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, origin: :human)
    Rails.cache.clear
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { raise Schwab::ServerError }
    features = described_class.snapshot(proposal)
    expect(features["values"].keys).to eq([ "open_risk_ratio" ])
    expect(features["missing"]["close_vs_sma20"]).to start_with("history unavailable")
    expect(features["missing"]["return63_less_spy"]).to start_with("history unavailable")
  end

  it "pins every version 1 formula on a fixed tape, and says the relative return is missing when SPY's last bar is not the instrument's" do
    zone = Time.find_zone!(MarketDay::ZONE)
    days = (1..120).map { MarketDay.today - it }.reject(&:on_weekend?).first(80).reverse
    serve = ->(spy_days) do
      Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) do |symbol|
        dates = symbol == "SPY" ? spy_days : days
        { "candles" => dates.each_with_index.map do |d, i|
            close = symbol == "SPY" ? 100 : 50 + i
            { "datetime" => zone.local(d.year, d.month, d.day, 6).to_i * 1000, "open" => close, "high" => close + 1, "low" => close - 1, "close" => close, "volume" => (i + 1) * 100 }
          end, "symbol" => symbol, "empty" => false }
      end
    end
    Schwab::FakeClient.instance.reset!
    Rails.cache.clear
    serve.(days)
    proposal = OrderProposal.new(account: account, instrument: xyz)
    features = described_class.snapshot(proposal)
    expect(described_class::VERSION).to eq(1) # a changed formula changes these values: bump the version with them
    expect(features["values"]).to eq("atr14_ratio" => (2.0 / 129).round(6), "close_vs_sma20" => (129 / 119.5 - 1).round(6), "close_vs_sma50" => (129 / 104.5 - 1).round(6),
                                     "return63_less_spy" => (129.0 / 66 - 1).round(6), "volume_vs_avg20" => (8000 / 6950.0 - 1).round(6), "open_risk_ratio" => features["values"]["open_risk_ratio"])
    expect(features["missing"]).to include("close_vs_sma200" => "80 final candles; 200 needed")
    expect(features).to include("benchmark" => "SPY", "context" => include("open_risk_excluded"))
    Schwab::FakeClient.instance.reset!
    Rails.cache.clear
    serve.(days[0...-1])
    expect(described_class.snapshot(proposal)["missing"]["return63_less_spy"]).to include("is not SPY's")
  end

  it "reads nothing from a history whose last final candle is more than two trading days old" do
    Schwab::FakeClient.instance.reset!
    Rails.cache.clear
    script_price_history(ending: MarketDay.today - 10)
    features = described_class.snapshot(OrderProposal.new(account: account, instrument: xyz))
    expect(features["missing"]["close_vs_sma20"]).to match(/more than 2 trading days old/)
  end
end
