require "rails_helper"

RSpec.describe TradeLeg do
  it "links one leg per activity, which is what makes the journal builder idempotent" do
    activity = create(:activity)
    trade = create(:trade, account: activity.account, instrument: activity.instrument)
    trade.trade_legs.create!(activity: activity, kind: "entry", quantity: 40, price: 51.18, executed_at: activity.executed_at)
    expect { trade.trade_legs.create!(activity: activity, kind: "entry", quantity: 40, price: 51.18, executed_at: activity.executed_at) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect(activity.reload.trade_leg).to eq(trade.trade_legs.first)
  end

  it "allows synthetic legs with no activity or time" do
    trade = create(:trade, bootstrapped: true, needs_review: true)
    expect(trade.trade_legs.create!(kind: "entry", quantity: 40, price: 51.18)).to be_kind_entry
  end
end
