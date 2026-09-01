require "rails_helper"

RSpec.describe Setup, "#recompute_stats!" do
  it "counts only closed, reviewed, included trades with positive initial risk, and calls R above zero a win" do
    setup = create(:setup)
    account = create(:account)
    create(:trade, account: account, setup: setup, status: "closed", initial_risk: 100, realized_r: 2)
    create(:trade, account: account, setup: setup, status: "closed", initial_risk: 100, realized_r: -1)
    create(:trade, account: account, setup: setup, status: "closed", initial_risk: 100, realized_r: 0)
    create(:trade, account: account, setup: setup, status: "closed", initial_risk: 100, realized_r: 5, needs_review: true)
    create(:trade, account: account, setup: setup, status: "closed", initial_risk: 100, realized_r: 5, excluded_from_stats: true)
    create(:trade, account: account, setup: setup, status: "closed", initial_risk: nil, realized_r: nil)
    create(:trade, account: account, setup: setup, status: "open")
    setup.recompute_stats!
    expect(setup.sample_size).to eq(3)
    expect(setup.expectancy).to be_within(0.0001).of(BigDecimal("1") / 3)
    expect(setup.avg_r).to be_within(0.0001).of(BigDecimal("1") / 3)
    expect(setup.win_rate).to be_within(0.0001).of(BigDecimal("1") / 3)
  end
end
