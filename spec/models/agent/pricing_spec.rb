require "rails_helper"

RSpec.describe Agent::Pricing do
  it "prices the configured model with cache writes at 1.25x and reads at 0.1x" do
    expect(described_class::RATES).to have_key(Agent::MODEL)
    cost = described_class.cost("claude-sonnet-5", input_tokens: 1_000_000, output_tokens: 100_000, cache_creation_input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000)
    expect(cost).to eq(BigDecimal("2") + BigDecimal("1") + BigDecimal("2.5") + BigDecimal("0.2"))
  end

  it "prices an unknown model to nil, never zero" do
    expect(described_class.cost("claude-mystery", input_tokens: 10, output_tokens: 10)).to be_nil
  end
end
