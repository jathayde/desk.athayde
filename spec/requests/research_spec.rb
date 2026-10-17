require "rails_helper"

RSpec.describe "Research" do
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }

  it "reads the stored calibration, and says when there is none yet" do
    sign_in whitney
    get research_path
    expect(response.body).to include("No calibration yet")
    CalibrationSnapshot.create!(as_of: Date.new(2026, 10, 10), scope: "author", key: "agent", label: "Agent",
                                figures: { "n" => 24, "open" => 3, "instruments" => 9, "voids" => { "never_entered" => 2 }, "brier" => 0.21, "baseline_brier" => 0.24, "hindsight_brier" => 0.23,
                                           "skill" => 0.03, "skill_interval" => [ -0.02, 0.08 ], "hit_rate" => 0.5, "hit_rate_if_ambiguous_hit" => 0.58, "ambiguous" => 2,
                                           "mean_probability" => 0.55, "mean_baseline" => 0.41, "mean_reward_to_risk" => 2.0 })
    CalibrationSnapshot.create!(as_of: Date.new(2026, 10, 10), scope: "author", key: "human", label: "Operator", figures: { "n" => 4, "open" => 0, "instruments" => 4 })
    travel_to Date.new(2026, 10, 12) do
      get research_path
    end
    expect(response.body).to include("As of Sat Oct 10", "Agent</b>: not distinguishable from the baseline", "Brier 0.210", "baseline 0.240", "2 never entered",
                                     "Operator</b>: not enough forecasts yet (4 scored; 20 needed)", "Not enough forecasts for a reliability table")
    travel_to Date.new(2026, 10, 20) do
      get research_path
    end
    expect(response.body).to include("Last computed Sat Oct 10", "no Saturday run has written any since")
  end
end
