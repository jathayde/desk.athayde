# Rule 5: no earnings or economic calendar until FMP (Phase 2.5); shown as not checked, acknowledged on every entry.
class Guardrails::EarningsBlackout < Guardrails::Rule
  def evaluate = entry? ? unavailable("earnings and economic calendar are not available in Phase 2") : skipped
end
