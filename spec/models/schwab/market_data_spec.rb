require "rails_helper"

RSpec.describe Schwab::MarketHours do
  it "maps an open day with full session bounds in Eastern time" do
    hours = described_class.from(schwab_fixture("market_hours_open"), date: Date.new(2026, 9, 8))
    expect(hours).to be_open
    expect(hours.session_opens_at).to eq(Time.utc(2026, 9, 8, 11))
    expect(hours.regular_opens_at).to eq(Time.utc(2026, 9, 8, 13, 30))
    expect(hours.regular_closes_at).to eq(Time.utc(2026, 9, 8, 20))
    expect(hours.session_closes_at).to eq(Time.utc(2026, 9, 9, 0))
  end

  it "reads an early close from a shorter regular session" do
    raw = schwab_fixture("market_hours_open")
    raw["equity"]["EQ"]["sessionHours"]["regularMarket"] = [ { "start" => "2026-09-08T09:30:00-04:00", "end" => "2026-09-08T13:00:00-04:00" } ]
    expect(described_class.from(raw, date: Date.new(2026, 9, 8)).regular_closes_at).to eq(Time.utc(2026, 9, 8, 17))
  end

  it "treats the closed-day shape, and a missing equity key, as closed" do
    expect(described_class.from(schwab_fixture("market_hours_closed"), date: Date.new(2026, 9, 7))).not_to be_open
    expect(described_class.from({}, date: Date.new(2026, 9, 7))).not_to be_open
  end
end

RSpec.describe Schwab::Quote do
  it "splits quotes from invalid symbols across pages" do
    batch = described_class.batch([ schwab_fixture("quotes"), { "ABC" => { "symbol" => "ABC" }, "errors" => { "invalidSymbols" => [ "ZZZ" ] } } ])
    expect(batch.invalid_symbols).to eq(%w[ NOPE ZZZ ])
    expect(batch.quotes.map(&:symbol)).to eq(%w[ XYZ DEF ABC ])
    expect(batch.quotes.first).to have_attributes(cusip: "037833100", last: BigDecimal("53.0"), net_change: BigDecimal("0.6"))
    expect(batch.quotes.first.quote_time).to eq(Time.utc(2026, 9, 1, 13, 4))
    expect(batch.quotes.last.last).to be_nil
  end
end

RSpec.describe Schwab::PriceHistory do
  it "maps candles with New York dates" do
    history = described_class.from(schwab_fixture("price_history"))
    expect(history.symbol).to eq("XYZ")
    expect(history).not_to be_empty
    expect(history.previous_close).to eq(BigDecimal("52.4"))
    expect(history.candles.map(&:date)).to eq([ Date.new(2026, 8, 31), Date.new(2026, 9, 1) ])
    expect(history.candles.last.close).to eq(BigDecimal("53.0"))
  end

  it "handles an empty series and rejects a candle without a datetime" do
    expect(described_class.from({ "symbol" => "X", "empty" => true })).to be_empty
    expect { described_class.from({ "candles" => [ { "open" => 1 } ] }) }.to raise_error(Schwab::MappingError)
  end
end
