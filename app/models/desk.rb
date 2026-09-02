# The desk as one read model, for the glance screen, the briefs, and the agent tools: one place that decides the banner, the numbers, and their freshness.
# Everything it reads is already in the database; a page render never calls Schwab.
class Desk
  STALE_MULTIPLIER = 2
  Row = Data.define(:position, :protection, :as_of, :stale, :trade) do
    def symbol = position.instrument.symbol
  end

  def initialize(account: nil)
    @settings = SystemSettings.instance
    @account = account || Account.trading.order(:id).first
    @in_session = MarketDay.known_session_open?
  end

  attr_reader :account, :settings

  def state
    return :not_connected if token_status == :missing
    return :waiting_for_accounts if Account.none?
    return :needs_setup if account.nil?
    return :waiting_first_sync if balance.nil?
    :ready
  end

  def token_status = @token_status ||= SchwabToken.status
  def token = @token ||= SchwabToken.current
  def halted? = @settings.manual_halt?
  def halt_reason = @settings.manual_halt_reason
  def halted_by = @halted_by ||= AuditEvent.where(kind: "manual_halt_set").order(created_at: :desc).first
  def sync_paused_reason = @settings.sync_paused_reason

  # The current pause episode, not the first one in history.
  def sync_paused_since
    since = token ? SyncRun.skipped_token.where(started_at: token.issued_at..) : SyncRun.skipped_token
    since.minimum(:started_at)
  end

  def rule_halted? = @settings.rule_halted?
  delegate :rule_halt_rule, :rule_halt_reason, :rule_halt_resets_at, to: :@settings

  def pending_proposal_count = @pending_proposal_count ||= account ? account.order_proposals.pending.count : 0
  def hand_placement_count = @hand_placement_count ||= account ? account.order_proposals.awaiting_hand_placement.count : 0
  def unresolved_submissions = @unresolved_submissions ||= account ? account.order_proposals.submission_unknown.includes(:instrument).order(:id).to_a : []
  def unprotected_rows = @unprotected_rows ||= ready? ? rows.select { |r| r.protection == :unprotected } : []

  # The primary banner, highest severity first: the kill switch, then money in an unknown state, then a dead
  # connection, then an unprotected position, then the week's nag. Everything else active shows as a status line.
  def banner
    return :halted if halted?
    return :submission_unknown if unresolved_submissions.any?
    return token_status if %i[ revoked expired ].include?(token_status)
    return :unprotected if unprotected_rows.any?
    token_status if token_status == :expiring
  end

  def secondary_statuses
    primary = banner
    statuses = []
    statuses << token_status if token_status != :healthy && token_status != primary && state != :not_connected
    statuses << :rule_halted if rule_halted?
    statuses << :submission_unknown if unresolved_submissions.any? && primary != :submission_unknown
    statuses << :unprotected if unprotected_rows.any? && primary != :unprotected
    statuses << :sync_paused if sync_paused_reason.present? && %i[ revoked expired missing ].exclude?(token_status)
    statuses << :sync_failed if sync_failure
    statuses << :calendar_fallback if MarketDay.find_by(date: MarketDay.today)&.fallback?
    statuses
  end

  # The latest feed failure nothing has succeeded since. Nil until an account exists and the token works.
  def sync_failure
    return @sync_failure if defined?(@sync_failure)
    @sync_failure = account && SchwabToken.usable? ? unresolved_failures.max_by(&:started_at) : nil
  end

  def ready? = state == :ready
  # A feed's latest failure while nothing has succeeded on it since; nil once it recovered.
  def unresolved_failure(feed)
    run = account&.last_sync_failure(feed)
    run if run && unresolved?(run)
  end

  def balance = @balance ||= account&.current_balance
  def latest_snapshot = @latest_snapshot ||= account && account.snapshots.chronological.last
  def equity = balance&.equity

  # Flow-adjusted change since the prior snapshot by date, never by recency.
  def prior_snapshot
    return @prior_snapshot if defined?(@prior_snapshot)
    @prior_snapshot = account && account.snapshots.where(as_of: ...MarketDay.today).order(as_of: :desc).first
  end

  def day_change
    return nil unless equity && prior_snapshot
    flows = Snapshot.net_flows(account, after: prior_snapshot.as_of, through: MarketDay.today) or return nil # an unpriced flow: unknown, not zero
    equity - flows - prior_snapshot.equity
  end

  def day_change_ratio = day_change && prior_snapshot.equity.positive? ? day_change / prior_snapshot.equity : nil
  def day_change_label = prior_snapshot ? "since #{prior_snapshot.as_of.strftime('%a')} close" : "first snapshot after today's close"

  def rows
    @rows ||= begin
      trades = account.trades.open.index_by(&:instrument_id)
      account.positions.includes(:instrument, :working_stop_order).map do |position|
        Row.new(position: position, protection: position.protection, as_of: as_of_for(position), stale: stale_row?(position), trade: trades[position.instrument_id])
      end.sort_by { |r| [ { protected: 1, delisted: 2 }.fetch(r.protection, 0), r.position.distance_to_stop || -BigDecimal("Infinity"), r.position.instrument.symbol ] }
    end
  end

  def open_risk = rows.select { |r| r.protection == :protected }.sum { |r| r.position.open_risk }
  def open_risk_ratio = equity && equity.positive? ? open_risk / equity : nil
  def excluded_by_reason = rows.reject { |r| r.protection == :protected }.group_by(&:protection).transform_values(&:size)
  def review_count = account ? account.trades.needing_review.count : 0
  def balance_stale? = balance && stale?(balance.as_of, :positions)
  def orders_as_of = @orders_as_of ||= account&.last_sync(:orders)

  # Stale: older than twice the cadence the tick would use right now plus its minute of slack, or any age once sync is paused.
  def stale?(time, feed)
    return true if time.nil? || sync_paused_reason.present?
    time < Time.current - (sync_interval(feed) * STALE_MULTIPLIER + 1.minute)
  end

  private
    def sync_interval(feed) = (@intervals ||= {})[feed] ||= account.sync_interval(feed, in_session: @in_session)

    # Every row's protection state depends on the orders feed, judged by its own cadence: "no stop" is only as
    # current as the last orders sync.
    def stale_row?(position) = stale?(position.synced_at, :positions) || stale?(orders_as_of, :orders)
    def as_of_for(position) = [ position.synced_at, orders_as_of ].compact.min

    def unresolved_failures
      SyncRun::ACCOUNT_FEEDS.filter_map { |feed| account.last_sync_failure(feed) }.select { |run| unresolved?(run) }
    end

    # Unresolved: nothing has succeeded on that feed since it failed.
    def unresolved?(run)
      succeeded_at = account.last_sync(run.feed)
      succeeded_at.nil? || run.started_at > succeeded_at
    end
end
