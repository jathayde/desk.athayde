require "rails_helper"

RSpec.describe Research::Calibration do
  let(:account) { create(:account) }
  let(:breakout) { create(:setup, name: "Breakout") }
  let(:monday) { Date.new(2026, 10, 5) }
  let(:as_of) { monday + 60 } # every window below has closed, and a week more

  # A scored forecast on its own name and week unless told otherwise: entry 50, stop 47, target 56, horizon 10.
  def forecast(outcome:, probability: 0.6, baseline: 0.3, author: "agent", instrument: create(:instrument), starts_on: monday, setup: nil, proposal: nil, saw: false, **detail)
    proposal ||= create(:order_proposal, account: account, instrument: instrument, status: "rejected", target_price: 56, reference_close: 50, reference_on: starts_on - 1, setup: setup)
    Forecast.create!(order_proposal: proposal, author: author, probability: probability, baseline_probability: baseline, horizon_days: 10, entry_price: 50, stop_price: 47, target_price: 56,
                     reference_close: 50, reference_on: starts_on - 1, reference_volatility: 0.02, starts_on: starts_on, checked_through: starts_on + 5, outcome: outcome,
                     void_reason: outcome == "void" ? "never_entered" : nil, resolved_at: outcome && Time.current, saw_agent_forecast: saw, detail: detail.stringify_keys)
  end

  def calibration(at = as_of) = described_class.new(Forecast.includes(order_proposal: :setup).order(:id).to_a, as_of: at)
  def figures(scope = "overall", key = "all", at: as_of)
    c = calibration(at)
    c.figures(c.cuts.find { it.scope == scope && it.key == key })
  end

  it "scores against each forecast's own baseline, and stores nothing but counts below the floor" do
    10.times { forecast(outcome: "hit", probability: 0.6, baseline: 0.3) }
    10.times { forecast(outcome: "miss", probability: 0.6, baseline: 0.3) }
    f = figures
    expect(f).to include("n" => 20, "hit_rate" => 0.5, "brier" => 0.26, "baseline_brier" => 0.29, "hindsight_brier" => 0.25, "skill" => 0.03)
    expect(f["skill_interval"].size).to eq(2)
    expect(f).not_to include("reliability")
    nineteen = described_class.new(Forecast.includes(order_proposal: :setup).order(:id).first(19), as_of: as_of)
    below = nineteen.figures(nineteen.cuts.first)
    expect(below).to include("n" => 19)
    expect(below).not_to include("brier", "skill")
  end

  it "shows a forecaster who knows something as better than the baseline, with quintiles from 50" do
    30.times { |i| forecast(outcome: "hit", probability: 0.9, starts_on: monday + i * 7) }
    30.times { |i| forecast(outcome: "miss", probability: 0.1, starts_on: monday + i * 7) }
    f = figures(at: monday + 300)
    expect(f["skill_interval"].first).to be > 0
    expect(f["reliability"].map { it["n"] }).to eq([ 12 ] * 5)
    expect(f["reliability"].first).to include("mean_probability" => 0.1, "observed" => 0.0)
    expect(CalibrationSnapshot.new(figures: f.deep_stringify_keys).verdict).to eq("better than the baseline")
  end

  it "waits for a forecast's last possible session before scoring it, so fast outcomes never run ahead of slow ones" do
    forecast(outcome: "hit")
    forecast(outcome: nil)
    early = figures(at: monday + 10)
    expect(early).to include("n" => 0, "maturing" => 1, "open" => 1)
    expect(figures).to include("n" => 1, "maturing" => 0)
  end

  it "counts a bet on a name once across its planned window, keeps voids out of the score but in the counts" do
    name = create(:instrument)
    forecast(outcome: "miss", instrument: name, starts_on: monday)
    forecast(outcome: "hit", instrument: name, starts_on: monday + 3) # inside the first one's planned window
    forecast(outcome: "hit", instrument: name, starts_on: monday + 28)
    forecast(outcome: "void")
    expect(figures).to include("n" => 2, "overlapping" => 1, "voids" => { "never_entered" => 1 }, "instruments" => 1)
  end

  it "counts one forecast per proposal where the authors are mixed, and pairs only blind forecasts on the same session, whole" do
    shared = create(:order_proposal, account: account, instrument: create(:instrument), status: "rejected", target_price: 56, reference_close: 50, reference_on: monday - 1, setup: breakout)
    forecast(outcome: "hit", proposal: shared)
    forecast(outcome: "hit", proposal: shared, author: "human")
    looked = create(:order_proposal, account: account, instrument: create(:instrument), status: "rejected", target_price: 56, reference_close: 50, reference_on: monday - 1)
    forecast(outcome: "miss", proposal: looked)
    forecast(outcome: "miss", proposal: looked, author: "human", saw: true)
    late = create(:order_proposal, account: account, instrument: create(:instrument), status: "rejected", target_price: 56, reference_close: 50, reference_on: monday - 1)
    forecast(outcome: "miss", proposal: late)
    forecast(outcome: "miss", proposal: late, author: "human", starts_on: monday + 1)
    c = calibration
    cuts = c.cuts.to_h { [ [ it.scope, it.key ], it.forecasts.size ] }
    expect(cuts).to include([ "overall", "all" ] => 3, [ "author", "agent" ] => 3, [ "author", "human" ] => 3, [ "paired", "agent" ] => 1, [ "paired", "human" ] => 1,
                            [ "setup", breakout.id.to_s ] => 1, [ "setup", "none" ] => 2)
    expect(c.figures(c.cuts.find { it.scope == "paired" && it.key == "agent" })).to include("anchored_excluded" => 1)
  end

  it "is stored each Saturday with one audit row, a rerun replacing the day" do
    forecast(outcome: "hit")
    2.times { Research::CalibrationJob.perform_now(as_of) }
    expect(CalibrationSnapshot.where(as_of: as_of).pluck(:scope, :key)).to include([ "overall", "all" ], [ "author", "agent" ], [ "paired", "human" ])
    expect(CalibrationSnapshot.where(as_of: as_of, scope: "overall").sole.n).to eq(1)
    expect(CalibrationSnapshot.find_by(as_of: as_of, scope: "author", key: "human").coverage).to eq("entries" => 1, "forecast" => 0) # the factory proposal is the operator's, unforecast
    expect(AuditEvent.where(kind: "calibration_computed").count).to eq(2)
  end
end
