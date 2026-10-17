require "rails_helper"

RSpec.describe Research::ResolveForecastsJob do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:monday) { Date.new(2026, 10, 5) }
  let(:zone) { Time.find_zone!(MarketDay::ZONE) }

  def forecast_on(instrument, horizon: 3)
    proposal = create(:order_proposal, account: account, instrument: instrument, status: "rejected", limit_price: 50, stop_price: 47, target_price: 56, reference_close: 50, reference_on: monday)
    Forecast.create!(order_proposal: proposal, author: "agent", probability: 0.4, horizon_days: horizon, entry_price: 50, stop_price: 47, target_price: 56,
                     reference_close: 50, reference_on: monday, starts_on: monday + 1, made_at: zone.local(2026, 10, 5, 11))
  end

  # Weekday candles from Monday, [low, high] closing at the middle, as Schwab's daily history would serve them.
  def serve(symbol, *bars)
    days = (0..20).map { monday + it }.reject(&:on_weekend?)
    candles = bars.each_with_index.map do |(low, high), i|
      { "datetime" => zone.local(days[i].year, days[i].month, days[i].day, 6).to_i * 1000, "open" => low, "high" => high, "low" => low, "close" => (low + high) / 2.0, "volume" => 1 }
    end
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { |sym| sym == symbol ? { "candles" => candles, "symbol" => sym, "empty" => false } : raise(Schwab::ServerError) }
  end

  def night(date) = travel_to(zone.local(date.year, date.month, date.day, 17, 20)) { described_class.perform_now }

  it "resolves on final candles only, with one audit row per forecast resolved and one for the run" do
    forecast = forecast_on(xyz)
    serve("XYZ", [ 49, 51 ], [ 49.5, 52 ], [ 51, 56.5 ])
    night(monday + 2) # Wednesday's candle is still the session's own: not read
    expect(forecast.reload).to have_attributes(outcome: nil, checked_through: monday + 1)
    night(monday + 3)
    expect(forecast.reload).to have_attributes(outcome: "hit", checked_through: monday + 2)
    expect(forecast.detail).to include("entered_on" => (monday + 1).iso8601, "decided_on" => (monday + 2).iso8601)
    expect(AuditEvent.where(kind: "forecast_resolved").sole.data).to include("outcome" => "hit")
    expect(AuditEvent.where(kind: "forecasts_checked").last.data).to include("open" => 1, "results" => { "hit" => 1 })
  end

  it "waits out nights without usable candles and voids the fifth as data unavailable" do
    forecast = forecast_on(xyz)
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { raise Schwab::ServerError }
    4.times { |i| night(monday + 7 + i) }
    expect(forecast.reload).to have_attributes(outcome: nil)
    expect(forecast.detail["failed_nights"]).to eq(4)
    night(monday + 11)
    expect(forecast.reload).to have_attributes(outcome: "void", void_reason: "data_unavailable")
  end

  it "settles a name that ended without a successor on what history is left, none included: a miss once entered, never entered otherwise" do
    entered = forecast_on(xyz)
    gone = create(:instrument, symbol: "GONE")
    unentered = forecast_on(gone)
    serve("XYZ", [ 49, 51 ], [ 49.5, 52 ])
    night(monday + 3)
    expect(entered.reload.detail).to include("entered_on" => (monday + 1).iso8601)
    [ xyz, gone ].each { it.update!(delisted_at: Time.current) }
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { |symbol| { "candles" => [], "symbol" => symbol, "empty" => true } } # what a dead symbol serves
    night(monday + 4)
    expect(entered.reload).to have_attributes(outcome: "miss")
    expect(entered.detail).to include("ended_early" => true)
    expect(unentered.reload).to have_attributes(outcome: "void", void_reason: "never_entered")
  end

  it "counts failed nights in a row: a night that reads candles starts the count again" do
    forecast = forecast_on(xyz, horizon: 20)
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { raise Schwab::ServerError }
    3.times { |i| night(monday + 7 + i) }
    Schwab::FakeClient.instance.reset!
    serve("XYZ", [ 49, 51 ], *[ [ 49.5, 51 ] ] * 8)
    night(monday + 10)
    expect(forecast.reload.detail).not_to include("failed_nights")
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { raise Schwab::ServerError }
    Rails.cache.clear
    4.times { |i| night(monday + 14 + i) }
    expect(forecast.reload).to have_attributes(outcome: nil)
    expect(forecast.detail["failed_nights"]).to eq(4)
  end

  it "counts a night as failed when the history skips a session or ends too long ago to be tonight's" do
    forecast = forecast_on(xyz, horizon: 20)
    serve("XYZ", [ 49, 51 ], [ 49.5, 52 ])
    night(monday + 3)
    expect(forecast.reload.detail).not_to include("failed_nights")
    night(monday + 8) # the history still ends on Tuesday: a name that stopped trading, or Schwab behind
    expect(forecast.reload.detail["failed_nights"]).to eq(1)
  end

  it "stops at a rate limit and names what it did not reach" do
    forecast_on(xyz)
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { raise Schwab::RateLimited.new(retry_after: 30) }
    night(monday + 7)
    expect(Forecast.open.count).to eq(1)
    expect(AuditEvent.where(kind: "forecasts_checked").last.data["skipped"]).to eq("XYZ" => "not reached: Schwab rate limit")
  end
end
