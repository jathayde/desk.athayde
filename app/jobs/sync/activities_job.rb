module Sync
  # Activities for one account, one request per transaction type a cash account produces. A bad request on
  # one type fails the run so the cursor does not advance past rows that were never fetched; the rows that
  # did arrive are still upserted and will simply be seen again. A malformed record is quarantined alone.
  # A type Schwab rejects (an assumed type this account does not have; a 4xx is never transient) is left out
  # for the rest of the New York day and asked for once tomorrow, so one wrong guess costs one failed run a
  # day instead of every run. Never all of them: see types_to_skip.
  class ActivitiesJob < FeedJob
    OVERLAP = 3.days

    limits_concurrency to: 1, key: ->(account) { "activities-#{account.id}" }, on_conflict: :discard

    def perform(account)
      from, to, gap_from = window_for(:activities, account, overlap: OVERLAP)
      SyncRun.record(:activities, account: account, window_from: from, window_to: to) do |run|
        note_gap(run, gap_from, account)
        @earliest_flow = nil
        outcome = :succeeded
        (Schwab::Activity::CASH_ACCOUNT_TYPES - types_to_skip(account)).each do |type|
          raws = client.transactions(account.schwab_hash, from: from, to: to, type: type)
          raws.each { |raw| upsert(account, raw, run) }
          run.touched(raws.size)
        rescue Schwab::RequestError => e
          run.quarantine(:activity_types_rejected, { "type" => type, "error" => e.message })
          reject_type!(account, type, e)
          outcome = :failed
        end
        hand_off_to_journal(account) if account.trading_enabled?
        outcome
      end
    end

    private
      # The day's skip list is its audit rows. Never everything: a rejection every type shares is our window or
      # our token, not the types, and a run that skipped them all would report success on an empty fetch and
      # advance the cursor past rows nobody read.
      def types_to_skip(account)
        skipped = rejections_today(account).map { |event| event.data["type"] }
        skipped.size < Schwab::Activity::CASH_ACCOUNT_TYPES.size ? skipped : []
      end

      def reject_type!(account, type, error)
        return if rejections_today(account).any? { |event| event.data["type"] == type }
        AuditEvent.log("activity_type_skipped", actor: :system, subject: account, reason: "#{type} rejected: #{error.message}; asked for again tomorrow", data: { type: type })
        @rejections_today = nil
      end

      def rejections_today(account)
        @rejections_today ||= AuditEvent.where(kind: "activity_type_skipped", subject: account, created_at: MarketDay.today.all_day).to_a
      end

      def hand_off_to_journal(account)
        Journal::LinkFillsJob.perform_later(account)
        Snapshots::RebuildJob.perform_later(account, from: @earliest_flow) if @earliest_flow
      end

      # A directional type whose cash sign points the other way is recorded but called out.
      def sign_disagrees?(activity, kind)
        return false if activity.net_amount.nil? || activity.net_amount.zero?
        (kind == :deposit && activity.net_amount.negative?) || (kind == :withdrawal && activity.net_amount.positive?)
      end

      def upsert(account, raw, run)
        activity = Schwab::Activity.from(raw)
        instrument = activity.instrument && Instrument.resolve(activity.instrument)
        if activity.instrument && instrument.nil?
          run.quarantine(:activities_unresolved, activity.instrument.to_h)
          return
        end
        row = account.activities.find_or_initialize_by(broker_activity_id: activity.activity_id)
        kind = activity.kind
        new_record = row.new_record?
        run.quarantine(:activity_kinds_other, activity.summary) if kind == :other && new_record
        row.assign_from(activity)
        row.update!(instrument: instrument, order: activity.order_id && account.orders.find_by(broker_order_id: activity.order_id))
        changed = row.saved_changes.keys.intersect?(%w[ quantity price status net_amount kind order_id ])
        row.unjournal! if row.journaled? && changed && !new_record
        run.quarantine(:flow_sign_disagreement, activity.summary) if new_record && sign_disagrees?(activity, kind)
        if row.cash_flow? && (new_record || changed) && row.trade_date
          @earliest_flow = [ @earliest_flow, row.trade_date ].compact.min
        end
      rescue Schwab::MappingError, ActiveRecord::RecordInvalid => e
        run.quarantine(:activities_unmapped, e.message)
      end
  end
end
