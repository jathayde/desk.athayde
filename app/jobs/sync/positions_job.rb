module Sync
  # Positions and balances for one account. Rows absent from the broker are deleted only when every
  # position resolved and the payload is sane. Zero-quantity positions are treated as absent.
  class PositionsJob < FeedJob
    limits_concurrency to: 1, key: ->(account) { "positions-#{account.id}" }, on_conflict: :discard

    def perform(account)
      SyncRun.record(:positions, account: account) do |run|
        summary = Schwab::AccountSummary.from(client.account(account.schwab_hash))
        raise Schwab::MappingError, "no positions but positive long market value" if summary.positions.empty? && summary.balances.long_market_value&.positive?

        now = Time.current
        held = summary.positions.reject { |p| p.quantity.zero? }
        kept = held.filter_map do |position|
          instrument = Instrument.resolve(position.instrument)
          unless instrument
            run.quarantine(:positions_unresolved, position.instrument.to_h)
            next
          end
          account.positions.find_or_initialize_by(instrument: instrument).tap do |row|
            row.update!(quantity: position.quantity, average_price: position.average_price, cost_basis: position.cost_basis,
                        market_value: position.market_value, last_price: last_price_for(position), synced_at: now, raw: position.raw)
          end
        rescue Schwab::MappingError => e
          run.quarantine(:positions_unmapped, e.message)
          nil
        end
        complete = kept.size == held.size
        account.positions.where.not(id: kept.map(&:id)).destroy_all if complete
        account.balances.create!(as_of: now, equity: summary.balances.equity, cash_available_for_trading: summary.balances.cash_available_for_trading,
                                 unsettled_cash: summary.balances.unsettled_cash, settled_cash: summary.balances.settled_cash,
                                 buying_power: summary.balances.buying_power, raw: summary.balances.raw)
        account.update!(last_synced_at: now, raw: summary.raw_without_positions)
        run.touched(kept.size)
        complete ? :succeeded : :partial
      end
    end

    private
      def last_price_for(position)
        return nil if position.quantity.zero? || position.market_value.nil?
        position.market_value / position.quantity
      end
  end
end
