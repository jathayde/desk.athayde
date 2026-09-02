module Sync
  # Orders for one account: the cursor window, a daily WORKING pass, and a re-fetch by id of any working
  # stop that fell out of the list, then working-stop detection on every position. Each order is mapped
  # inside its own rescue so one malformed record cannot poison the batch. Lineage is written in a second
  # pass by broker id and never nulled once set.
  class OrdersJob < FeedJob
    OVERLAP = 1.day
    PAGE_LIMIT = 3000

    limits_concurrency to: 1, key: ->(account, **) { "orders-#{account.id}" }, on_conflict: :discard

    def perform(account, working_pass: false)
      from, to, gap_from = window_for(:orders, account, overlap: OVERLAP)
      SyncRun.record(:orders, account: account, window_from: from, window_to: to) do |run|
        note_gap(run, gap_from, account)
        listed = client.orders(account.schwab_hash, from: from, to: to)
        truncated = listed.size >= PAGE_LIMIT
        listed += client.orders(account.schwab_hash, from: Time.current - LOOKBACK, to: to, status: Schwab::Order::WORKING) if working_pass || !working_pass_today?(account)
        orders = listed.filter_map { |raw| map(raw, run) }.flat_map(&:flatten)
        orders += refetch_missing_stops(account, orders, run)
        orders = orders.reverse.uniq(&:order_id).reverse # the later snapshot of a repeated order wins

        rows = orders.filter_map { |order| upsert(account, order, run) }
        link_lineage(account, orders)
        Orders::ProposalLink.call(account)
        # A truncated page or an order the run could not map or resolve cannot say what is working; a stop Schwab
        # no longer returns is known, and its position must lose it.
        complete = !truncated && run.unmapped_values.except("stops_gone").none?
        account.positions.includes(:working_stop_order).each(&:assign_working_stop!) if complete
        run.touched(rows.size)
        truncated ? :partial : :succeeded
      end
    end

    private
      def map(raw, run)
        Schwab::Order.from(raw)
      rescue Schwab::MappingError => e
        run.quarantine(:orders_unmapped, e.message)
        nil
      end

      def working_pass_today?(account)
        SyncRun.for(:orders, account).advanced_cursor.where(started_at: Time.current.in_time_zone(MarketDay::ZONE).beginning_of_day..).exists?
      end

      # A stop Schwab no longer returns even by id is marked gone, so assignment drops it instead of trusting a stale row.
      def refetch_missing_stops(account, orders, run)
        seen = orders.map(&:order_id)
        account.positions.includes(:working_stop_order).filter_map(&:working_stop_order).reject { |o| seen.include?(o.broker_order_id) }.flat_map do |stop|
          Schwab::Order.from(client.order(account.schwab_hash, stop.broker_order_id)).flatten
        rescue Schwab::RequestError => e
          stop.update!(status: Schwab::Order::GONE)
          run.quarantine(:stops_gone, "#{stop.broker_order_id}: #{e.message}")
          []
        end
      end

      def upsert(account, order, run)
        instrument = order.instrument && Instrument.resolve(order.instrument)
        if order.instrument && instrument.nil?
          run.quarantine(:orders_unresolved, order.instrument.to_h)
          return nil
        end
        row = account.orders.find_or_initialize_by(broker_order_id: order.order_id)
        row.placed_via = :schwab_direct if row.new_record?
        row.update!(instrument: instrument, status: order.status, side: order.side, quantity: order.quantity, filled_quantity: order.filled_quantity,
                    remaining_quantity: order.remaining_quantity, order_type: order.order_type, limit_price: order.price, stop_price: order.stop_price,
                    duration: order.duration, session: order.session, tax_lot_method: order.tax_lot_method, strategy_type: order.strategy_type,
                    entered_at: order.entered_at, closed_at: order.close_time, raw: order.raw)
        row
      rescue Schwab::MappingError, ActiveRecord::RecordInvalid => e
        run.quarantine(:orders_unmapped, "#{order.order_id}: #{e.message}")
        nil
      end

      # Parents may already exist from an earlier run, so the index covers every id the batch references.
      def link_lineage(account, orders)
        ids = orders.flat_map { |o| [ o.order_id, o.parent_order_id, o.replaces_order_id ] }.compact.uniq
        by_broker_id = account.orders.where(broker_order_id: ids).index_by(&:broker_order_id)
        orders.each do |order|
          row = by_broker_id[order.order_id] or next
          parent = order.parent_order_id && by_broker_id[order.parent_order_id]
          replaced = order.replaces_order_id && by_broker_id[order.replaces_order_id]
          row.update!(parent_order: parent) if parent && row.parent_order_id.nil?
          row.update!(replaces_order: replaced) if replaced && row.replaces_order_id.nil?
        end
      end
  end
end
