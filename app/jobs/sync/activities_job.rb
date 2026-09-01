module Sync
  # Activities for one account, one request per transaction type a cash account produces. A bad request on
  # one type fails the run so the cursor does not advance past rows that were never fetched; the rows that
  # did arrive are still upserted and will simply be seen again. A malformed record is quarantined alone.
  class ActivitiesJob < FeedJob
    OVERLAP = 3.days

    limits_concurrency to: 1, key: ->(account) { "activities-#{account.id}" }, on_conflict: :discard

    def perform(account)
      from, to, gap_from = window_for(:activities, account, overlap: OVERLAP)
      SyncRun.record(:activities, account: account, window_from: from, window_to: to) do |run|
        note_gap(run, gap_from, account)
        outcome = :succeeded
        Schwab::Activity::CASH_ACCOUNT_TYPES.each do |type|
          raws = client.transactions(account.schwab_hash, from: from, to: to, type: type)
          raws.each { |raw| upsert(account, raw, run) }
          run.touched(raws.size)
        rescue Schwab::RequestError => e
          run.quarantine(:activity_types_rejected, "#{type}: #{e.message}")
          outcome = :failed
        end
        outcome
      end
    end

    private
      def upsert(account, raw, run)
        activity = Schwab::Activity.from(raw)
        instrument = activity.instrument && Instrument.resolve(activity.instrument)
        if activity.instrument && instrument.nil?
          run.quarantine(:activities_unresolved, activity.instrument.to_h)
          return
        end
        row = account.activities.find_or_initialize_by(broker_activity_id: activity.activity_id)
        kind = activity.kind
        run.quarantine(:activity_kinds_other, activity.summary) if kind == :other && row.new_record?
        row.update!(instrument: instrument, order: activity.order_id && account.orders.find_by(broker_order_id: activity.order_id),
                    broker_order_id: activity.order_id, kind: kind, status: activity.status, sub_type: activity.type, side: activity.side,
                    quantity: activity.quantity, price: activity.price, commission: activity.commission, fees: activity.fees,
                    net_amount: activity.net_amount, trade_date: activity.trade_date, settlement_date: activity.settlement_date,
                    executed_at: activity.executed_at, raw: activity.raw)
      rescue Schwab::MappingError, ActiveRecord::RecordInvalid => e
        run.quarantine(:activities_unmapped, e.message)
      end
  end
end
