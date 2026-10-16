module Allocation
  # 17:10 New York on trading days, once the off-hours tick has synced positions and the balance after the close:
  # one drift row per active target, one audit row per drift and one for the run. Proposes nothing yet: a row
  # outside its band is reported, and step 2's planner is what turns reported drift into a proposal.
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

      Allocation::Drift.transaction do
        recorded = lines.filter_map { |line| record(line, day.date) }
        AuditEvent.log("allocation_drift_checked", actor: :system, data: { as_of: day.date.iso8601, actions: recorded.map(&:action).tally,
                                                                           reasons: lines.first.detail["reasons"] }.compact)
      end
    end

    private
      # A rerun on the same day rewrites the row, except one that already proposed, which keeps the numbers it
      # proposed from, and a measured row a failed rerun would blank: the run's audit row still names the reasons.
      def record(line, as_of)
        drift = line.target.drifts.find_or_initialize_by(as_of: as_of)
        return if drift.order_proposal_id || (drift.persisted? && !drift.action_unavailable? && line.action == "unavailable")
        drift.update!(line.to_h.except(:target).merge(target_weight: line.target.target_weight))
        AuditEvent.log("allocation_drift_recorded", actor: :system, subject: drift,
                       data: { target: line.target.label, action: drift.action, drift: drift.drift&.to_s, band: drift.band&.to_s, notional: drift.notional&.to_s })
        drift
      end
  end
end
