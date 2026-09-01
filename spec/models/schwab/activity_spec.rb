require "rails_helper"

RSpec.describe Schwab::Activity do
  let(:activities) { Schwab::Scrub.json(schwab_fixture("transactions")).map { |a| described_class.from(a) } }

  it "maps a fill: security item, fee items summed, side from position effect" do
    fill = activities[0]
    expect(fill).to have_attributes(activity_id: "95012345678", type: "TRADE", order_id: "1004055538123", side: "BUY", quantity: 40,
                                    price: BigDecimal("51.18"), position_effect: "OPENING", net_amount: BigDecimal("-2047.25"))
    expect(fill.fees).to eq(BigDecimal("0.05"))
    expect(fill.commission).to eq(0)
    expect(fill.instrument.cusip).to eq("037833100")
    expect(fill.securities.size).to eq(1)
    expect(fill.trade_date).to eq(Date.new(2026, 8, 14))
    expect(fill.settlement_date).to eq(Date.new(2026, 8, 15))
    expect(fill.executed_at).to eq(Time.utc(2026, 8, 14, 14, 3, 11))
  end

  it "derives side from the net amount when position effect is absent" do
    expect(described_class.from({ "activityId" => 1, "type" => "TRADE", "tradeDate" => "2026-08-14T00:00:00+0000", "netAmount" => 12.5 }).side).to eq("SELL")
  end

  it "maps a dividend with its instrument, no side, and no share quantity" do
    dividend = activities[1]
    expect(dividend).to have_attributes(type: "DIVIDEND_OR_INTEREST", side: nil, quantity: nil, price: nil, net_amount: BigDecimal("9.6"))
    expect(dividend.instrument.symbol).to eq("XYZ")
  end

  it "maps a cash deposit with no instrument" do
    deposit = activities[2]
    expect(deposit.instrument).to be_nil
    expect(deposit.securities).to be_empty
    expect(deposit.net_amount).to eq(1000)
  end

  it "falls back to tradeDate when time is missing, and keeps a CUSIP-less instrument" do
    sweep = activities[3]
    expect(sweep.executed_at).to eq(Time.utc(2026, 8, 23))
    expect(sweep.instrument).to have_attributes(symbol: "SWVXX", cusip: nil)
  end

  it "keeps both securities of a corporate action" do
    raw = { "activityId" => 9, "type" => "RECEIVE_AND_DELIVER", "tradeDate" => "2026-08-14T00:00:00+0000", "transferItems" => [
      { "instrument" => { "assetType" => "EQUITY", "cusip" => "111111111", "symbol" => "OLD" }, "amount" => -10 },
      { "instrument" => { "assetType" => "EQUITY", "cusip" => "222222222", "symbol" => "NEW" }, "amount" => 5 } ] }
    activity = described_class.from(raw)
    expect(activity.securities.map { |s| s.instrument.cusip }).to eq(%w[ 111111111 222222222 ])
    expect(activity.quantity).to be_nil
  end

  it "raises MappingError without any time or id" do
    expect { described_class.from({ "activityId" => 1 }) }.to raise_error(Schwab::MappingError)
    expect { described_class.from({ "time" => "2026-08-14T00:00:00+0000" }) }.to raise_error(Schwab::MappingError)
  end
end
