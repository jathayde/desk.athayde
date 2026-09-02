module Sync
  # Runs after every re-auth: accounts first, then every feed for every account, bypassing due checks.
  # Windows derive from each feed's last cursor, so a short pause needs nothing special and a long one is
  # audited by the feed job as an unrecoverable gap. Activities run inline before positions are enqueued:
  # a positions sync that lands first would plug every trade bought during the pause and flag every one
  # closed during it, and the journal would be wrong until the next cycle.
  class CatchUpJob < ApplicationJob
    def perform
      AccountsJob.perform_now
      Account.find_each do |account|
        ActivitiesJob.perform_now(account)
        PositionsJob.perform_later(account)
        OrdersJob.perform_later(account, working_pass: true)
      end
    end
  end
end
