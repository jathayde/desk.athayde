require "rails_helper"

RSpec.describe Schwab::Activity, "#kind" do
  def kind_of(type:, securities: [], net_amount: nil, fee_only: false)
    items = securities.map { |s| { "instrument" => { "assetType" => s, "symbol" => "X", "cusip" => "1" }, "amount" => 1 } }
    items = [ { "instrument" => { "assetType" => "CURRENCY", "symbol" => "CURRENCY_USD" }, "amount" => -1, "feeType" => "SEC_FEE" } ] if fee_only
    described_class.from({ "activityId" => 1, "type" => type, "tradeDate" => "2026-08-14T00:00:00+0000", "netAmount" => net_amount, "transferItems" => items }).kind
  end

  it "classifies cash-account realities" do
    expect(kind_of(type: "TRADE", securities: %w[ EQUITY ], net_amount: -100)).to eq(:fill)
    expect(kind_of(type: "TRADE", securities: %w[ CASH_EQUIVALENT ], net_amount: -100)).to eq(:sweep)
    expect(kind_of(type: "TRADE", securities: %w[ COLLECTIVE_INVESTMENT ], net_amount: -100)).to eq(:fill)
    expect(kind_of(type: "DIVIDEND_OR_INTEREST", securities: %w[ CASH_EQUIVALENT ], net_amount: 0.4)).to eq(:interest)
    expect(kind_of(type: "JOURNAL", net_amount: -2, fee_only: true)).to eq(:fee)
    expect(kind_of(type: "MONEY_MARKET", net_amount: 5)).to eq(:sweep)
    expect(kind_of(type: "DIVIDEND_OR_INTEREST", securities: %w[ EQUITY ], net_amount: 9.6)).to eq(:dividend)
    expect(kind_of(type: "DIVIDEND_OR_INTEREST", net_amount: 0.4)).to eq(:interest)
    expect(kind_of(type: "ELECTRONIC_FUND", net_amount: 1000)).to eq(:deposit)
    expect(kind_of(type: "WIRE_OUT", net_amount: -1000)).to eq(:withdrawal)
    expect(kind_of(type: "JOURNAL", net_amount: -500)).to eq(:withdrawal)
    expect(kind_of(type: "JOURNAL", securities: %w[ EQUITY ])).to eq(:transfer)
    expect(kind_of(type: "RECEIVE_AND_DELIVER", securities: %w[ EQUITY EQUITY ])).to eq(:corporate_action)
    expect(kind_of(type: "MEMORANDUM", fee_only: true)).to eq(:fee)
    expect(kind_of(type: "SMA_ADJUSTMENT")).to eq(:other)
  end
end
