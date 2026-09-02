# Built in, never a data rule: the kill switch stops everything, a rule halt stops entries (SystemSettings owns both).
class Guardrails::Halt < Guardrails::Rule
  def evaluate
    settings = context.settings
    return block(reason: "halted: #{settings.manual_halt_reason}") unless settings.exits_allowed?
    return block(reason: "entries halted by #{settings.rule_halt_rule}: #{settings.rule_halt_reason}") if entry? && !settings.entries_allowed?
    pass
  end
end
