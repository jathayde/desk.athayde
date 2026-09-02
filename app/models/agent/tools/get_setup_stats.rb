class Agent::Tools::GetSetupStats < Agent::Tool
  tool description: "Per-setup expectancy over closed, reviewed, included trades with a positive initial risk (legacy holdings and excluded trades " \
                    "never count). A win is R above zero. Treat a small sample_size as no evidence.",
       output: { setups: { type: "array", items: { type: "object" } }, eligibility: { type: "string" } }

  def call
    { setups: Setup.order(:name).map { |s| { name: s.name, active: s.active?, definition: s.definition, sample_size: s.sample_size, win_rate: s.win_rate,
                                             avg_r: s.avg_r, expectancy: s.expectancy, stats_computed_at: s.stats_computed_at } },
      eligibility: "closed, reviewed, not excluded, not bootstrapped, initial_risk > 0" }
  end
end
