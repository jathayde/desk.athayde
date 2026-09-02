module Snapshots
  # Rechains forward from a date in place, for a flow or balance that landed late. Existing rows keep their
  # risk columns; a day that cannot be built is left as it was.
  class RebuildJob < ApplicationJob
    # Block, never discard: nothing re-enqueues a rebuild, and a discarded one leaves every later index wrong.
    limits_concurrency to: 1, key: ->(account, *) { "snapshots-#{account.id}" }, on_conflict: :block

    def perform(account, from:)
      SyncRun.record(:snapshots, account: account) do |run|
        (from.to_date..MarketDay.today).each { |date| Snapshot.record(account, date, run: run) }
      end
    end
  end
end
