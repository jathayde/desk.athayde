module Allocation
  # 17:10 New York on trading days, once the off-hours tick has synced positions and the balance after the close:
  # one drift row per active target, then the planner's verdict on each (a rebalance proposal, or why not), one
  # audit row per drift and one for the run. Never calls a model or a Schwab order endpoint.
  class DriftJob < ApplicationJob
    DUE_AT = { hour: 17, min: 15 } # config/recurring.yml runs it at 17:10; a row is overdue once this minute passes

    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    # Today only: a past day would be measured with today's balance and prices. A fallback calendar row calls
    # every weekday a session, so only Schwab's word that the market traded counts, as for the snapshot.
    def perform(date = MarketDay.today)
      return unless date == MarketDay.today
      day = MarketDay.for(date)
      return unless day.schwab? && day.trading?
      account = Account.trading.order(:id).first or return
      lines = Allocation::Book.new(account, day: day).lines
      return if lines.empty?

      planner = Allocation::Planner.new(account, day: day, expires_at: MarketDay.next_trading_day_after(day.date)&.regular_closes_at) # before any lock: it may ask Schwab
      Allocation::Drift.transaction do
        recorded = lines.filter_map { |line| record(line, day.date, planner) }
        AuditEvent.log("allocation_drift_checked", actor: :system, data: { as_of: day.date.iso8601, actions: recorded.map(&:action).tally,
                                                                           reasons: lines.first.detail["reasons"] }.compact)
      end
    end

    private
      # A rerun on the same day rewrites the row, except one that already proposed, which keeps the numbers it
      # proposed from, and a measured row a failed rerun would blank: the run's audit row still names the reasons.
      # Each line in its own savepoint, so whatever goes wrong planning one target is that row's verdict, not the
      # run's end: the row is still written, as reported with the error, and the error is reported.
      def record(line, as_of, planner)
        drift = line.target.drifts.find_or_initialize_by(as_of: as_of)
        return if drift.order_proposal_id || drift.thesis_review&.decision.present? || (drift.persisted? && !drift.action_unavailable? && line.action == "unavailable")
        verdict = Allocation::Drift.transaction(requires_new: true) do
          drift.update!(line.to_h.except(:target).merge(target_weight: line.target.target_weight))
          planner.plan(line, drift)
        end
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { job: self.class.name, target: line.target.id })
        drift = line.target.drifts.find_or_initialize_by(as_of: as_of) # the savepoint took a new row with it
        verdict = Allocation::Planner::Verdict.new(action: "reported", detail: { "error" => e.message.truncate(200) }, proposal: nil, thesis_review: nil)
        write(drift, line, verdict)
      else
        write(drift, line, verdict)
      end

      def write(drift, line, verdict)
        Allocation::Drift.transaction(requires_new: true) do
          drift.update!(line.to_h.except(:target, :action, :detail).merge(target_weight: line.target.target_weight, action: verdict.action,
                                                                           detail: line.detail.merge(verdict.detail), order_proposal: verdict.proposal,
                                                                           thesis_review: verdict.thesis_review))
          AuditEvent.log("allocation_drift_recorded", actor: :system, subject: drift,
                         data: { target: line.target.label, action: drift.action, drift: drift.drift&.to_s, band: drift.band&.to_s, notional: drift.notional&.to_s,
                                 proposal: verdict.proposal&.id, thesis_review: verdict.thesis_review&.id }.compact)
        end
        drift
      end
  end
end
