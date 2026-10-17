require "rails_helper"

RSpec.describe StopCollar::Candles do
  let(:zone) { Time.find_zone!(MarketDay::ZONE) }
  let(:today) { Date.new(2026, 10, 14) }
  let(:candles) { [ { date: today - 1, close: 1 }, { date: today, close: 2 } ] }

  before { MarketDay.create!(date: today, trading: true, source: :schwab, fetched_at: Time.current, regular_opens_at: zone.local(2026, 10, 14, 9, 30), regular_closes_at: zone.local(2026, 10, 14, 16)) }

  it "takes today's bar as final only when it was fetched a settle after the close, whatever the clock says now" do
    expect(described_class.final(candles, fetched_at: zone.local(2026, 10, 14, 15, 58)).map { it[:date] }).to eq([ today - 1 ]) # cached at 15:58, read at 16:05
    expect(described_class.final(candles, fetched_at: zone.local(2026, 10, 14, 16, 5)).map { it[:date] }).to eq([ today - 1 ]) # not yet settled
    expect(described_class.final(candles, fetched_at: zone.local(2026, 10, 14, 16, 15)).map { it[:date] }).to eq([ today - 1, today ])
    expect(described_class.final(candles, fetched_at: zone.local(2026, 10, 15, 8)).map { it[:date] }).to eq([ today - 1, today ]) # the next morning
  end
end
