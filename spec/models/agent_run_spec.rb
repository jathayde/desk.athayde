require "rails_helper"

RSpec.describe AgentRun do
  it "allows one non-failed run per kind and market day, and a retry after a failure" do
    described_class.create!(kind: :eod, market_date: Date.new(2026, 9, 1), status: :failed, started_at: Time.current)
    described_class.create!(kind: :eod, market_date: Date.new(2026, 9, 1), status: :succeeded, started_at: Time.current)
    expect { described_class.create!(kind: :eod, market_date: Date.new(2026, 9, 1), status: :running, started_at: Time.current) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(described_class.served?(:eod, Date.new(2026, 9, 1))).to be(true)
    expect(described_class.served?(:morning_brief, Date.new(2026, 9, 1))).to be(false)
  end

  it "sweeps a running row a killed worker left behind, and only that" do
    stuck = described_class.create!(kind: :morning_brief, market_date: Date.new(2026, 9, 1), status: :running, started_at: 25.minutes.ago)
    live = described_class.create!(kind: :eod, market_date: Date.new(2026, 9, 1), status: :running, started_at: 2.minutes.ago)
    described_class.sweep_stale!
    expect(stuck.reload).to have_attributes(status: "failed", error: "left running")
    expect(live.reload.status).to eq("running")
  end

  it "titles itself by kind and market day" do
    run = described_class.new(kind: :morning_brief, market_date: Date.new(2026, 9, 1))
    expect(run.title).to eq("morning brief, Tue Sep 1")
  end
end
