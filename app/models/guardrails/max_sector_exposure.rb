# Rule 2b: no sector source until FMP (Phase 2.5); shown as not checked, acknowledged on every entry.
class Guardrails::MaxSectorExposure < Guardrails::Rule
  def evaluate = entry? ? unavailable("sector data is not available in Phase 2") : skipped
end
