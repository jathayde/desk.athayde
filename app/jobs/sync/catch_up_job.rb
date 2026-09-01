module Sync
  # Runs after every re-auth: accounts first, then every feed for every account, bypassing due checks.
  # Windows derive from each feed's last cursor, so a short pause needs nothing special and a long one is
  # audited by the feed job as an unrecoverable gap.
  class CatchUpJob < ApplicationJob
    def perform
      AccountsJob.perform_now
      Account.find_each do |account|
        PositionsJob.perform_later(account)
        OrdersJob.perform_later(account, working_pass: true)
        ActivitiesJob.perform_later(account)
      end
    end
  end
end
