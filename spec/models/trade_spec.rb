require "rails_helper"

RSpec.describe Trade do
  it "separates lifecycle from completeness" do
    trade = create(:trade, status: "closed", needs_review: true)
    expect(Trade.closed).to include(trade)
    expect(Trade.needing_review).to include(trade)
    expect(Trade.open).not_to include(trade)
  end

  it "allows one open trade per account and instrument, any number closed" do
    trade = create(:trade)
    create(:trade, account: trade.account, instrument: trade.instrument, status: "closed")
    expect { create(:trade, account: trade.account, instrument: trade.instrument) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "lists closed trades missing a post-mortem, treating blank as missing" do
    done = create(:trade, status: "closed", post_mortem: "held to target")
    blank = create(:trade, status: "closed", post_mortem: "   ")
    expect(Trade.missing_post_mortem).to contain_exactly(blank)
    expect(Trade.missing_post_mortem).not_to include(done)
  end

  it "knows when R can be computed" do
    expect(build(:trade, initial_risk: nil)).not_to be_realized_r_available
    expect(build(:trade, initial_risk: 92)).to be_realized_r_available
  end
end
