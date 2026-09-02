# Rule 2a: a new instrument may not push the count of held and pending positions past the cap.
class Guardrails::MaxPositions < Guardrails::Rule
  def self.fatal_when_missing? = true

  def evaluate
    return skipped unless entry?
    held = context.positions.count
    pending = context.pending_new_positions
    detail = { held: held, pending: pending, cap: param(:count) }
    return pass(**detail, adding: false) if context.position_for(proposal.instrument)
    held + pending + 1 <= param(:count) ? pass(**detail) : block(**detail)
  end
end
