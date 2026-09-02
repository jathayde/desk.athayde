require "rails_helper"

RSpec.describe MarketDay do
  let(:fake) { Schwab::FakeClient.instance }

  it "fetches a Schwab-sourced row and keeps it" do
    day = MarketDay.for(Date.new(2026, 9, 8))
    expect(day).to be_schwab.and be_trading
    expect(day.regular_closes_at).to eq(Time.utc(2026, 9, 8, 20))
    MarketDay.for(Date.new(2026, 9, 8))
    expect(fake.calls.map(&:first)).to eq([ :market_hours ])
  end

  it "falls back to a weekday row when Schwab is unreachable, and re-fetches it until Schwab answers" do
    fake.enqueue(:market_hours) { raise Schwab::ServerError.new("down", status: 503) }
    day = MarketDay.for(Date.new(2026, 9, 8))
    expect(day).to be_fallback.and be_trading
    expect(day.regular_opens_at).to eq(Time.utc(2026, 9, 8, 13, 30))
    expect(MarketDay.for(Date.new(2026, 9, 8))).to be_schwab
    expect(MarketDay.count).to eq(1)
  end

  it "falls back to closed on a weekend" do
    fake.enqueue(:market_hours) { raise Schwab::TransportError.new("timeout") }
    expect(MarketDay.for(Date.new(2026, 9, 5))).to be_fallback.and not_be_trading
  end

  it "knows whether the session is open and whether the day has closed" do
    travel_to Time.zone.parse("2026-09-08 10:00 EDT") do
      expect(MarketDay.session_open?).to be(true)
    end
    travel_to Time.zone.parse("2026-09-08 21:30 EDT") do
      expect(MarketDay.session_open?).to be(false)
    end
  end

  it "computes today in New York, not UTC" do
    travel_to Time.utc(2026, 9, 9, 1, 0) do # 21:00 ET on the 8th
      expect(MarketDay.today).to eq(Date.new(2026, 9, 8))
    end
  end
end

RSpec::Matchers.define_negated_matcher :not_be_trading, :be_trading
