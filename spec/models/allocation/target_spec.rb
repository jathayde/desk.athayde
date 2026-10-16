require "rails_helper"

RSpec.describe Allocation::Target do
  let(:john) { create(:user, approver: true) }
  let(:xyz) { create(:instrument, symbol: "XYZ") }

  it "adds, reweighs, and retires with one audit row each carrying before and after" do
    target = described_class.add!(symbol: xyz.symbol, target_percent: "25", user: john)
    target.reweigh!("30", user: john)
    target.retire!(user: john)
    expect(target.reload).to have_attributes(active: false, target_weight: BigDecimal("0.3"))
    expect(AuditEvent.where(kind: "allocation_target_changed").order(:id).map(&:data)).to eq([
      { "target" => "XYZ", "before" => nil, "after" => { "target_weight" => "0.25", "active" => true } },
      { "target" => "XYZ", "before" => { "target_weight" => "0.25", "active" => true }, "after" => { "target_weight" => "0.3", "active" => true } },
      { "target" => "XYZ", "before" => { "target_weight" => "0.3", "active" => true }, "after" => { "target_weight" => "0.3", "active" => false } }
    ])
  end

  it "refuses an active set past 100 percent, a target naming both or neither, and a second active target for the same thing" do
    described_class.add!(asset_class: " Bonds ", target_percent: "60", user: john)
    expect(described_class.sole.asset_class).to eq("bonds")
    expect { described_class.add!(symbol: xyz.symbol, target_percent: "50", user: john) }.to raise_error(ActiveRecord::RecordInvalid, /110.0%, past 100%/)
    expect(AuditEvent.where(kind: "allocation_target_changed").count).to eq(1) # the refused add left nothing behind
    expect(described_class.new(instrument: xyz, asset_class: "bonds", target_weight: 0.1)).not_to be_valid
    expect(described_class.new(target_weight: 0.1)).not_to be_valid
    expect(described_class.new(instrument: xyz, target_weight: 0)).not_to be_valid
    expect { described_class.create!(asset_class: "bonds", target_weight: 0.1) }.to raise_error(ActiveRecord::RecordNotUnique)
    described_class.sole.retire!(user: john)
    expect(described_class.add!(symbol: xyz.symbol, target_percent: "50", user: john)).to be_active # a retired target no longer counts
  end

  it "refuses a weight too small to store, a reused symbol's delisted row, and a reweigh of a target retired meanwhile" do
    expect { described_class.add!(symbol: xyz.symbol, target_percent: "0.00001", user: john) }.to raise_error(ActiveRecord::RecordInvalid, /greater than 0/)
    old = create(:instrument, symbol: "XYZ", cusip: "999999999")
    old.delist!(user: john)
    expect(described_class.add!(symbol: "xyz", target_percent: "10", user: john).instrument).to eq(xyz)
    target = described_class.sole
    stale = described_class.find(target.id)
    target.retire!(user: john)
    expect { stale.reweigh!("20", user: john) }.to raise_error(ActiveRecord::StaleObjectError)
    expect(target.reload).to have_attributes(active: false, target_weight: BigDecimal("0.1"))
  end
end
