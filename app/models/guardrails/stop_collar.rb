# Rule 8: the stop must sit inside the computed collar; bad or missing data is a block, and only a stop
# computed and outside the range is the overrideable caution (docs/phase-2-plan.md §0.10). When the percent
# floor is tighter than every method, the collar is the floor up to the entry.
class Guardrails::StopCollar < Guardrails::Rule
  def self.fatal_when_missing? = true

  def evaluate
    return skipped unless entry?
    return block(reason: "no collar computed") if proposal.collar.blank?
    collar = ::StopCollar::Collar.load(proposal.collar)
    return block(reason: collar.refusal) unless collar.ok?
    stop = proposal.stop_price.to_d
    ceiling = collar.floor_dominates ? proposal.limit_price.to_d : collar.tight
    inside = stop >= collar.wide && stop <= ceiling
    detail = { stop: stop, tight: collar.tight, wide: collar.wide, floor: collar.floor, floor_dominates: collar.floor_dominates, methods: collar.methods }
    inside ? pass(**detail) : caution(overridable: true, reason: "stop outside the collar", **detail)
  end
end
