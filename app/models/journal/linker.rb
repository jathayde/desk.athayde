# Links one account's activities into trades, one activity per transaction: find or insert the leg, recompute
# the trade from its legs, then stamp journaled_at last. A rerun finds the leg and recomputes. One failing
# activity flags its trade and is skipped, so the rest of the account keeps journaling.
class Journal::Linker
  RATIO_SCALE = 6

  def initialize(account)
    @account = account
    @closed_setups = []
  end

  def link_all!
    @account.activities.unjournaled.valid_for_journal.chronological.includes(:instrument, order: :order_proposal).each { |activity| link!(activity) }
    @account.activities.unjournaled.where.not(status: Schwab::Activity::VALID).update_all(journaled_at: Time.current)
    Setup.where(id: @closed_setups.uniq).find_each { |setup| Journal::RecomputeSetupStatsJob.perform_later(setup) }
  end

  def link!(activity)
    succession = resolve_succession(activity) if activity.corporate_action? # its CUSIP lookups at Schwab happen before the transaction opens
    Activity.transaction do
      linked = case activity.kind.to_sym
      when :fill then link_fill(activity)
      when :dividend, :interest then link_income(activity)
      when :transfer then link_transfer(activity)
      when :corporate_action then link_corporate_action(activity, succession)
      else true
      end
      activity.update!(journaled_at: Time.current) if linked
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Schwab::MappingError => e
    open_trade_for(activity.instrument)&.flag!(:corporate_action) if activity.instrument
    Rails.logger.warn("journal: skipped activity #{activity.broker_activity_id}: #{e.class} #{e.message}")
  end

  # Reconciles every open trade to the broker, but only when the broker row is newer than what the journal
  # has seen, so the positions/activities race cannot manufacture a plug or a missing-position flag.
  def reconcile_positions!
    positions = @account.positions.includes(:instrument).index_by(&:instrument_id)
    @account.trades.open.includes(:instrument).find_each do |trade|
      next if @account.activities.unjournaled.where(instrument_id: trade.instrument_id).exists?
      position = positions[trade.instrument_id]
      if position
        next if position.quantity <= 0 || position.average_price.nil? || position.synced_at < latest_fill_at(trade)
        trade.reconcile_plug!(broker_quantity: position.quantity, average_price: position.average_price)
      elsif activities_caught_up_past?(latest_fill_at(trade))
        trade.flag!(:position_missing)
      end
    end
    positions.each_value do |position|
      next if position.quantity <= 0 || position.average_price.nil? || @account.trades.open.exists?(instrument_id: position.instrument_id)
      next if @account.activities.unjournaled.where(instrument_id: position.instrument_id).exists?
      trade = @account.trades.create!(instrument: position.instrument, status: :open)
      trade.reconcile_plug!(broker_quantity: position.quantity, average_price: position.average_price)
    rescue ActiveRecord::RecordNotUnique
      next
    end
  end

  private
    def open_trade_for(instrument) = @account.trades.open.find_by(instrument: instrument)
    def latest_fill_at(trade) = trade.trade_legs.where.not(activity_id: nil).maximum(:executed_at) || Time.at(0)
    def activities_caught_up_past?(time) = (SyncRun.last_window_to(:activities, @account) || Time.at(0)) >= time

    # A fill with no side, quantity, or instrument stays unjournaled and visible rather than silently stamped.
    def link_fill(activity)
      return false if activity.instrument.nil? || activity.side.nil? || activity.quantity.nil?
      trade = open_trade_for(activity.instrument) || open_trade_from(activity)
      adopt_proposal(trade, activity)
      leg = trade.trade_legs.find_or_create_by!(activity: activity) do |l|
        l.kind = activity.buy? ? :entry : :exit
        l.quantity = activity.quantity
        l.price = activity.price
        l.cash_amount = activity.net_amount
        l.executed_at = activity.executed_at
      end
      earlier_legs = TradeLeg.joins(:trade).where(trades: { account_id: @account.id, instrument_id: activity.instrument_id }).where.not(id: leg.id).where.not(activity_id: nil)
      trade.flag!(:ordering_ambiguous) if earlier_legs.where("executed_at >= ?", leg.executed_at).exists?
      trade.recompute!
      @closed_setups << trade.setup_id if trade.closed? && trade.setup_id
      true
    end

    # A buy with no open trade starts one. A sell with no open trade is a legacy holding: bootstrap a plug that
    # covers what was held before the sale, priced from the position when there is one and unpriced otherwise.
    def open_trade_from(activity)
      trade = Trade.transaction(requires_new: true) { @account.trades.create!(instrument: activity.instrument, status: :open) }
      if activity.buy?
        proposal = activity.order&.order_proposal
        trade.flag!(:missing_setup) if proposal.nil?
      else
        position = @account.positions.find_by(instrument: activity.instrument)
        trade.reconcile_plug!(broker_quantity: (position&.quantity || 0) + activity.quantity, average_price: position&.average_price)
      end
      trade
    rescue ActiveRecord::RecordNotUnique
      open_trade_for(activity.instrument)
    end

    # The originating proposal's plan, taken whenever it becomes known (the order may sync after the fill).
    def adopt_proposal(trade, activity)
      proposal = activity.order&.order_proposal
      return if proposal.nil? || trade.order_proposal_id
      trade.update!(order_proposal: proposal, setup: proposal.setup, thesis: proposal.thesis, planned_stop: proposal.planned_stop, planned_target: proposal.target_price)
      trade.flag!(:missing_stop) if trade.planned_stop.nil?
      trade.clear_flag!(:missing_setup)
    end

    # Income lands on the open trade, else on a trade closed recently enough to have held the shares on the record date.
    def link_income(activity)
      return true if activity.instrument.nil?
      trade = open_trade_for(activity.instrument) ||
        @account.trades.closed.where(instrument: activity.instrument, closed_at: (activity.executed_at - Trade::DIVIDEND_AFTER_CLOSE_WINDOW)..).order(closed_at: :desc).first
      return true unless trade
      trade.trade_legs.find_or_create_by!(activity: activity) { |l| l.kind = :income; l.cash_amount = activity.net_amount; l.executed_at = activity.executed_at }
      trade.recompute!
      true
    end

    # Shares delivered onto an open trade: a clean ratio is a split or stock dividend, anything else is a transfer to review.
    def link_transfer(activity)
      delivered = activity.delivered_quantity
      return true if delivered.nil?
      trade = open_trade_for(activity.instrument) or return true
      return true if trade.trade_legs.exists?(activity: activity)
      ratio = split_ratio(trade.quantity, delivered)
      if ratio
        trade.trade_legs.create!(activity: activity, kind: :adjustment, ratio: ratio, quantity: delivered, cash_amount: 0, executed_at: activity.executed_at, note: "split or stock dividend")
      else
        trade.trade_legs.create!(activity: activity, kind: :adjustment, quantity: delivered, cash_amount: activity.net_amount, executed_at: activity.executed_at, note: "transfer")
        trade.flag!(:corporate_action)
      end
      trade.recompute!
      true
    end

    def split_ratio(running, delivered)
      return nil unless running.positive? && delivered.positive?
      ratio = (running + delivered) / running
      ratio if ratio > 1 && ratio == ratio.round(RATIO_SCALE)
    end

    Succession = Data.define(:delivered_out, :delivered_in, :predecessor, :successor)

    # Both sides of a succession, resolved once (with any CUSIP lookup at Schwab) before the transaction, so
    # inside it nothing waits on the wire.
    def resolve_succession(activity)
      securities = Schwab::Activity.from(activity.raw).securities
      out, into = securities.find { |s| s.amount&.negative? }, securities.find { |s| s.amount&.positive? }
      Succession.new(delivered_out: out, delivered_in: into, predecessor: out && Instrument.resolve(out.instrument), successor: into && Instrument.resolve(into.instrument))
    end

    # CUSIP succession: the predecessor's open trade moves to the successor, absorbing any unreviewed
    # bootstrapped trade the positions sync already opened there.
    def link_corporate_action(activity, succession)
      delivered_out, delivered_in, predecessor, successor = succession.deconstruct
      trade = predecessor && open_trade_for(predecessor)
      unless trade && successor
        [ predecessor, successor ].compact.each { |i| open_trade_for(i)&.flag!(:corporate_action) }
        return true
      end
      absorb_bootstrapped_trade(trade, successor)
      successor.update!(predecessor_instrument: predecessor) if successor.predecessor_instrument_id.nil? && successor != predecessor
      ratio = delivered_out.amount.abs.positive? ? delivered_in.amount / delivered_out.amount.abs : nil
      trade.update!(instrument: successor)
      trade.trade_legs.create!(activity: activity, kind: :adjustment, ratio: ratio, cash_amount: activity.net_amount, executed_at: activity.executed_at,
                               note: "succession #{predecessor.symbol} -> #{successor.symbol}")
      trade.flag!(:corporate_action) unless ratio
      trade.recompute!
      true
    end

    def absorb_bootstrapped_trade(trade, successor)
      other = open_trade_for(successor)
      return unless other && other.bootstrapped? && other.needs_review?
      other.trade_legs.where.not(activity_id: nil).update_all(trade_id: trade.id)
      other.destroy!
    end
end
