module Journal
  class BootstrapJob < ApplicationJob
    limits_concurrency to: 1, key: ->(account) { "journal-#{account.id}" }, on_conflict: :discard

    def perform(account)
      return unless account.trading_enabled?
      Journal::Linker.new(account).reconcile_positions!
    end
  end
end
