module Allocation
  # After each activities sync: a new deposit becomes a cash inflow and gets its policy's first action (a pending
  # deployment for tonight's check, its tranches, or a question). Writes rows only; proposals come from the check.
  class InflowJob < ApplicationJob
    limits_concurrency to: 1, key: ->(account) { "#{self.class.name}:#{account.id}" }

    def perform(account) = CashInflow.detect!(account)
  end
end
