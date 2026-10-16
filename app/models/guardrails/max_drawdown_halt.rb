# Rule 3: a drawdown from the high-water mark past the percent blocks entries and asks for a rule halt with no
# reset time; the operator clears it by hand. Read from the latest snapshot, so an intraday collapse is seen tonight.
class Guardrails::MaxDrawdownHalt < Guardrails::Rule
  def evaluate
    return skipped unless opens_exposure?
    return unavailable("no snapshot yet") if context.drawdown.nil?
    drawdown = context.drawdown * 100
    detail = { drawdown_percent: drawdown.round(2), cap: param(:percent) }
    return pass(**detail) if drawdown < param(:percent)
    [ :block, detail, false, { rule: rule_type, reason: "#{drawdown.round(2)}% below the high-water mark", resets_at: nil } ]
  end
end
