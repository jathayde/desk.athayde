# Rule 3: today's realized loss past the percent of yesterday's equity blocks entries and asks for a rule halt
# until the end of the New York day (the tick clears it before the next open); exits are not judged here.
class Guardrails::DailyLossHalt < Guardrails::Rule
  def evaluate
    return skipped unless opens_exposure?
    return unavailable("no prior snapshot to measure the day against") unless context.prior_equity&.positive?
    loss = -context.realized_today / context.prior_equity * 100
    detail = { loss_percent: loss.round(2), cap: param(:percent) }
    return pass(**detail) if loss < param(:percent)
    trip = { rule: rule_type, reason: "down #{loss.round(2)}% today", resets_at: Time.current.in_time_zone(MarketDay::ZONE).end_of_day }
    [ :block, detail, false, trip ]
  end
end
