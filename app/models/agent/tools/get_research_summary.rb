# The stored research figures, for the skeptic (docs/phase-2.6-plan.md §0.9): the latest calibration rows and every
# hypothesis's state, as the Saturday jobs and the decisions wrote them. Computes nothing. Not offered over MCP,
# so the agent that writes forecasts never reads its own calibration.
class Agent::Tools::GetResearchSummary < Agent::Tool
  tool description: "The desk's stored research figures: the latest weekly calibration of forecasts (per author, paired, per setup, with " \
                    "Brier scores against the baseline the levels and horizon imply, and a verdict) and every hypothesis with its status " \
                    "and frozen verdict. A figure below its floor is reported as not enough evidence.",
       output: { calibration_as_of: { type: [ "string", "null" ] }, calibration: { type: "array", items: { type: "object" } },
                 hypotheses: { type: "array", items: { type: "object" } } },
       mcp: false

  def call
    snapshots = CalibrationSnapshot.latest.to_a
    { calibration_as_of: snapshots.first&.as_of&.iso8601,
      calibration: snapshots.map { |s| { scope: s.scope, label: s.label, scored: s.n, verdict: s.verdict, brier: s.brier, baseline_brier: s.baseline_brier } },
      hypotheses: Hypothesis.includes(:setup).newest_first.map do |h|
        { id: h.id, statement: h.label, status: h.status, setup: h.setup&.name, min_sample: h.min_sample, expected_mean_r: h.expected_mean_r.to_s,
          verdict: h.evidence&.slice("n", "mean_r", "p_value", "bar", "clears") }
      end }
  end
end
