require "rails_helper"

RSpec.describe Schwab::RateBudget do
  before { Rails.cache.clear }

  it "raises once the shared per-minute budget is spent, with the seconds until the next window" do
    now = Time.zone.parse("2026-09-01 10:00:20")
    3.times { described_class.take!(now: now, budget: 3) }
    expect { described_class.take!(now: now, budget: 3) }.to raise_error(Schwab::RateLimited) { |e| expect(e.retry_after).to eq(40) }
    expect { described_class.take!(now: now + 1.minute, budget: 3) }.not_to raise_error
  end
end
