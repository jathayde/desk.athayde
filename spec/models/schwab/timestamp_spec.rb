require "rails_helper"

RSpec.describe Schwab::Timestamp do
  it "parses the three inbound formats" do
    expect(described_class.parse("2026-08-14T13:31:02+0000")).to eq(Time.utc(2026, 8, 14, 13, 31, 2))
    expect(described_class.parse("2026-08-14T13:31:02Z")).to eq(Time.utc(2026, 8, 14, 13, 31, 2))
    expect(described_class.parse("2026-09-08T09:30:00-04:00")).to eq(Time.utc(2026, 9, 8, 13, 30))
    expect(described_class.parse(1788267840000)).to eq(Time.utc(2026, 9, 1, 13, 4))
    expect(described_class.parse("1788267840000")).to eq(Time.utc(2026, 9, 1, 13, 4))
    expect(described_class.parse(nil)).to be_nil
    expect { described_class.parse("yesterday") }.to raise_error(Schwab::MappingError)
  end

  it "produces the three outbound formats" do
    t = Time.zone.parse("2026-08-14 09:31:02 EDT")
    expect(described_class.iso_ms(t)).to eq("2026-08-14T13:31:02.000Z")
    expect(described_class.date(t)).to eq("2026-08-14")
    expect(described_class.epoch_ms(t)).to eq(1786714262000)
  end

  it "reads daily candle stamps as New York dates and Schwab dates as UTC midnights" do
    expect(described_class.candle_date(1788148800000)).to eq(Date.new(2026, 8, 31))
    expect(described_class.parse_date("2026-08-14T00:00:00+0000")).to eq(Date.new(2026, 8, 14))
  end
end
