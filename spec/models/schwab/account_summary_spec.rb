require "rails_helper"

RSpec.describe Schwab::AccountSummary do
  subject(:summary) { described_class.from(Schwab::Scrub.json(schwab_fixture("account"))) }

  it "maps positions, tolerating a missing CUSIP on a cash equivalent" do
    expect(summary.account_type).to eq("CASH")
    xyz, second, sweep = summary.positions
    expect(xyz.instrument).to have_attributes(symbol: "XYZ", cusip: "037833100", instrument_id: 1001, asset_type: "EQUITY")
    expect(xyz.quantity).to eq(40)
    expect(xyz.average_price).to eq(BigDecimal("51.18"))
    expect(second.instrument.symbol).to eq("DEF")
    expect(sweep.instrument.cusip).to be_nil
    expect(sweep.quantity).to eq(BigDecimal("2110.5"))
  end

  it "maps balances and derives settled cash conservatively" do
    b = summary.balances
    expect(b.equity).to eq(BigDecimal("6508.55"))
    expect(b.settled_cash_by_subtraction).to eq(BigDecimal("2110"))
    expect(b.cash_available_for_withdrawal).to eq(BigDecimal("2110"))
    expect(b.settled_cash).to eq(BigDecimal("2110"))
    expect(b.buying_power).to be_nil
    expect(b.long_market_value).to eq(BigDecimal("3418.55"))
  end

  it "prefers the smaller settled-cash reading and survives a missing field" do
    b = Schwab::Balances.from({ "cashAvailableForTrading" => 1000, "unsettledCash" => 300, "cashAvailableForWithdrawal" => 650 })
    expect(b.settled_cash).to eq(650)
    expect(Schwab::Balances.from({ "cashAvailableForWithdrawal" => 5 }).settled_cash).to eq(5)
    expect(Schwab::Balances.from({}).settled_cash).to be_nil
  end

  it "raises MappingError when the wrapper or an instrument is missing" do
    expect { described_class.from({}) }.to raise_error(Schwab::MappingError)
    expect { Schwab::Position.from({ "longQuantity" => 1 }) }.to raise_error(Schwab::MappingError)
  end

  it "keeps zero quantities as BigDecimal" do
    expect(Schwab::Position.from({ "instrument" => { "symbol" => "X" } }).quantity).to be_a(BigDecimal)
  end
end
