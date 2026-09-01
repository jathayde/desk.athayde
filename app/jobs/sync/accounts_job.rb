module Sync
  # Discovers accounts by hash. New ones arrive unclassified and read-only until the operator sets them up.
  class AccountsJob < FeedJob
    def perform
      SyncRun.record(:accounts) do |run|
        hashes = client.account_numbers
        hashes.each { |hash| Account.find_or_create_by!(schwab_hash: hash) }
        run.touched(hashes.size)
      end
    end
  end
end
