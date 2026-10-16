require "rails_helper"

RSpec.describe Allocation::DiagnosticsJob do
  let(:zone) { Time.find_zone!("America/New_York") }
  let!(:token) { create(:schwab_token) }
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:xyz) { create(:instrument, symbol: "XYZ") }
  let!(:tlt) { create(:instrument, symbol: "TLT") }
  let(:john) { create(:user, approver: true) }
  let(:saturday) { Date.new(2026, 10, 17) }

  before do
    travel_to zone.local(2026, 10, 17, 8)
    { "rebalance_band" => { "percent" => "5" }, "cash_drag_weeks" => { "weeks" => "3" }, "correlation_threshold" => { "value" => "0.6", "window_days" => "20" } }
      .each { |type, params| RiskRule.create!(rule_type: type, params: params) }
    DeploymentPolicy.create!(mode: "immediate")
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 53, market_value: 2120)
    tlt.classify!(asset_class: nil, tags: %w[ diversifier ], user: john)
    Allocation::Target.add!(symbol: "XYZ", target_percent: "60", user: john) # leaves 40% intended cash
  end

  after { travel_back }

  # Daily candles riding one wave, so any two series move together.
  def history(close, days:)
    candles = (1..days).map do |i|
      date = saturday - 1 - (days - i)
      { "datetime" => zone.local(date.year, date.month, date.day, 6).to_i * 1000, "open" => close, "high" => close + 1, "low" => close - 1,
        "close" => close * (1 + Math.sin(i / 3.0) / 50), "volume" => 1_000_000 }
    end
    { "candles" => candles, "symbol" => "X", "empty" => false, "previousClose" => close }
  end

  def balance_on(date, cash:) = create(:balance, account: account, equity: 10_000, settled_cash: cash, unsettled_cash: 0, as_of: zone.local(date.year, date.month, date.day, 16, 30))

  it "counts the weeks the book has held more cash than its targets leave, back from this week, and flags past the threshold" do
    [ 0, 1, 2, 3 ].each { |back| balance_on(saturday - 1 - back.weeks, cash: 5000) } # 50% cash against 40% intended: 10 points over a 5-point band
    balance_on(saturday - 1 - 4.weeks, cash: 4200)
    described_class.perform_now(saturday)
    row = CashDragDiagnostic.sole
    expect(row).to have_attributes(cash_percent: BigDecimal("0.5"), intended_cash_percent: BigDecimal("0.4"), weeks_in_cash: 4, threshold_weeks: 3, flagged: true,
                                   deployment_policy: DeploymentPolicy.current)
    expect(AuditEvent.where(kind: "cash_drag_checked").sole.data).to include("weeks" => 4, "flagged" => true)
  end

  it "correlates each holding and each diversifier with SPY, names what it could not measure, and keeps what it computed when Schwab runs out of budget" do
    spy = create(:instrument, symbol: "SPY")
    create(:position, account: account, instrument: spy, quantity: 1, last_price: 400, market_value: 400) # held, but the benchmark only
    histories = { "SPY" => history(400, days: 40), "XYZ" => history(50, days: 40), "TLT" => history(90, days: 10) }
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { |symbol| histories.fetch(symbol) }
    described_class.perform_now(saturday)
    expect(Correlation.find_by!(instrument: xyz)).to have_attributes(as_of: saturday, window_days: 20, value: be_between(0.9, 1), last_close_on: saturday - 1) # both ride the same wave
    expect(Correlation.where(instrument: [ tlt, spy ])).to be_empty
    expect(AuditEvent.where(kind: "correlation_checked").sole.data).to include("computed" => 1, "skipped" => { "TLT" => "fewer than 21 shared closes" })

    Rails.cache.clear
    Schwab::FakeClient.instance.enqueue(:price_history) { |*| raise Schwab::RateLimited.new(retry_after: 60) }
    described_class.perform_now(saturday + 7)
    expect(AuditEvent.where(kind: "correlation_checked").last.data).to include("computed" => 0, "skipped" => { "XYZ" => "not reached: Schwab rate limit", "TLT" => "not reached: Schwab rate limit" })
  end

  it "measures a plain Pearson coefficient over the shared window, and says why when it cannot" do
    days = (1..6).map { Date.new(2026, 10, it) }
    up = days.each_with_index.to_h { |day, i| [ day, BigDecimal(100 + i * i) ] }
    down = days.each_with_index.to_h { |day, i| [ day, BigDecimal(100 - i * i) ] }
    expect(Correlation.measure(up, up, window: 5)).to have_attributes(value: 1, last_close_on: Date.new(2026, 10, 6))
    expect(Correlation.measure(up, down, window: 5).value).to be < -0.9
    expect(Correlation.measure(up, days.to_h { [ it, BigDecimal(100) ] }, window: 5).reason).to eq("no variance in window")
    expect(Correlation.measure(up, up, window: 6).reason).to eq("fewer than 7 shared closes")
    expect(Correlation.measure(up.except(days.last), up, window: 4).reason).to eq("history ends 2026-10-05")
    expect(Correlation.measure(up.except(days[2]).merge(Date.new(2026, 9, 20) => 99), up.merge(Date.new(2026, 9, 20) => 99), window: 5).reason).to eq("gap in history")
    expect(Correlation.measure(up.merge(days.last => BigDecimal(300)), up, window: 5).reason).to eq("possible split in window")
  end

  it "counts from the latest week that has a balance when this week has none yet, and says why the count stopped" do
    [ 1, 2 ].each { |back| balance_on(saturday - 1 - back.weeks, cash: 5000) }
    balance_on(saturday - 1 - 3.weeks, cash: 4100)
    described_class.perform_now(saturday)
    expect(CashDragDiagnostic.sole).to have_attributes(weeks_in_cash: 2, flagged: false, cash_percent: BigDecimal("0.5"),
                                                       detail: hash_including("weeks_back_to_start" => 1, "ended" => "inside the band"))
  end

  it "runs the correlations even when the cash-drag step fails" do
    allow(CashDragDiagnostic).to receive(:record!).and_raise("boom")
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { |symbol| history(symbol == "SPY" ? 400 : 50, days: 40) }
    described_class.perform_now(saturday)
    expect(AuditEvent.where(kind: "correlation_checked").sole.data["computed"]).to eq(2) # XYZ held, TLT a diversifier
  end
end
