# The only path to Schwab's order endpoint (docs/phase-2-plan.md §0.1, §0.6, §0.7): the approve gesture,
# two transactions, one live attempt, shadow mode as the branch between "would have" and a real call.
module Submission
  class Refused < StandardError; end
end
