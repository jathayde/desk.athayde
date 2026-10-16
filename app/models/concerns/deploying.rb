# New cash on its way into the book (docs/phase-2.5-plan.md §8, step 4): a deposit deployed at once, or one staged
# tranche. A night either places it (some target took a share), finishes it (every share was too small, not
# short, or held back by the operator), or defers it to the next night, up to DEFERRED_NIGHTS, after which the
# including class gives up its own way. A halt waits without counting. The including class supplies placed!(results)
# and give_up!(results).
module Deploying
  extend ActiveSupport::Concern

  DEFERRED_NIGHTS = 5 # nights new cash waits on unsettled cash or a waiting proposal before it is left as cash
  NOTHING_TONIGHT = { "tonight" => "no calendar or no target to place it" }.freeze

  def deploy!(planner)
    outcomes = planner.deploy(self, amount)
    return change_status!(status, halted_on: Date.current.iso8601) if outcomes == :halted
    results = outcomes&.to_h { [ it.target, it.result ] }
    return placed!(results) if outcomes&.any?(&:proposed?)
    return give_up!(results) if outcomes&.none?(&:deferred?)
    nights = detail["deferred_nights"].to_i + 1
    nights >= DEFERRED_NIGHTS ? give_up!(results || NOTHING_TONIGHT, deferred_nights: nights) : change_status!(status, deferred_nights: nights, outcomes: results || NOTHING_TONIGHT)
  end
end
