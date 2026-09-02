class Agent::Tools::GetSetupStats < Agent::Tool
  tool description: "Per-setup expectancy over closed, reviewed, included trades with a positive initial risk (legacy holdings and excluded trades " \
                    "never count). A win is R above zero. Treat a small sample_size as no evidence.",
       output: { setups: { type: "array", items: { type: "object" } }, eligibility: { type: "string" } }

  def call = Setup.agent_stats
end
