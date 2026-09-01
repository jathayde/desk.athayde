module Journal
  class LinkFillsJob < ApplicationJob
    limits_concurrency to: 1, key: ->(account) { "journal-#{account.id}" }, on_conflict: :discard

    def perform(account)
      return unless account.trading_enabled?
      linker = Journal::Linker.new(account)
      linker.link_all!
      linker.reconcile_positions!
    end
  end
end
