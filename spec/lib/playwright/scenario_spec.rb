require "rails_helper"

RSpec.describe Playwright::Scenario do
  it "loads every scenario from an empty database with the seeded users in place" do
    described_class::SCENARIOS.each do |name|
      expect { described_class.load!(name) }.not_to raise_error, name
      expect(User).to exist, name
    end
    described_class.load!("rule_halted")
    expect(SystemSettings.instance).to be_rule_halted
  end

  it "takes a dashed name as the same scenario and refuses one it does not know" do
    described_class.load!("proposal-warn")
    expect(OrderProposal.sole.warnings).to include("wash_sale")
    expect { described_class.load!("nope") }.to raise_error(ArgumentError)
  end
end
