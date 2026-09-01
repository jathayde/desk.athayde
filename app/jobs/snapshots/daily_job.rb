module Snapshots
  class DailyJob < ApplicationJob
    limits_concurrency to: 1, key: ->(account, *) { "snapshots-#{account.id}" }, on_conflict: :discard

    def perform(account, date = MarketDay.today)
      SyncRun.record(:snapshots, account: account) do |run|
        snapshot = Snapshot.record(account, date, run: run)
        run.touched(snapshot ? 1 : 0)
      end
    end
  end
end
