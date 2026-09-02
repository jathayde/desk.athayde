require "rails_helper"

RSpec.describe Sizing do
  let(:rule) { RiskRule.create!(rule_type: "max_risk_per_trade", params: { "percent" => "1.0" }) }

  it "floors the risk budget over the per-share risk to whole shares and shows its work" do
    sizing = described_class.for(limit_price: BigDecimal("50"), stop_price: BigDecimal("48"), equity: BigDecimal("6500"), rule: rule)
    expect(sizing).to have_attributes(quantity: 32, risk_budget: BigDecimal("65"), per_share_risk: BigDecimal("2"), reason: nil)
    expect(sizing).to be_sized
    expect(sizing.to_h.keys).to include("equity", "quantity")
  end

  it "refuses with the reason when there is no equity, no rule, a stop at or above the entry, or a budget below one share" do
    expect(described_class.for(limit_price: 50, stop_price: 48, equity: nil, rule: rule).reason).to eq("no fresh equity")
    expect(described_class.for(limit_price: 50, stop_price: 48, equity: 6500, rule: nil).reason).to eq("no max_risk_per_trade rule")
    expect(described_class.for(limit_price: 50, stop_price: 50, equity: 6500, rule: rule).reason).to eq("stop must be below the entry")
    expect(described_class.for(limit_price: 50, stop_price: 48, equity: 6500, rule: RiskRule.new(rule_type: "max_risk_per_trade", params: { "percent" => "0" })).reason).to include("positive")
    expect(described_class.for(limit_price: 50.0, stop_price: 48.0, equity: 6500.0, rule: rule).quantity).to eq(32) # floats are coerced, never carried
    tiny = described_class.for(limit_price: BigDecimal("500"), stop_price: BigDecimal("400"), equity: BigDecimal("6500"), rule: rule)
    expect(tiny).not_to be_sized
    expect(tiny.reason).to include("buys no whole share")
  end
end
