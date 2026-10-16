# The book's weights against its targets after one market day's close (docs/phase-2.5-plan.md §0.4). Weights come
# from the desk's own numbers and only from a balance and a positions sync taken after that close, with a price
# for every instrument any target covers; short of that, every line is unavailable with the reasons named, never
# a partial book, since a class weight depends on every member. Weight, band, and drift are fractions of equity.
class Allocation::Book
  Line = Data.define(:target, :weight, :close, :band, :drift, :notional, :quantity, :action, :detail) do
    def side = notional.positive? ? "buy" : "sell"
  end

  # Positions no active target covers, by instrument or by class: shown, never proposed against. A membership
  # read over targets and positions, not a drift, so a page may ask it.
  def self.unallocated(account)
    targets = Allocation::Target.active
    account.positions.joins(:instrument).includes(:instrument)
           .where.not(instrument_id: targets.where.not(instrument_id: nil).select(:instrument_id))
           .where("instruments.asset_class IS NULL OR instruments.asset_class NOT IN (?)", targets.where.not(asset_class: nil).select(:asset_class))
           .order("instruments.symbol")
  end

  def initialize(account, day:)
    @account, @day = account, day
  end

  def lines
    @lines ||= begin
      problems = stale_inputs
      problems = unpriced_inputs if problems.empty?
      targets.map { |target| problems.any? ? unavailable(target, problems) : judge(target) }
    end
  end

  private
    attr_reader :account, :day

    def targets = @targets ||= Allocation::Target.active.includes(:instrument).order(:id).to_a
    def positions = @positions ||= account.positions.includes(:instrument).index_by(&:instrument_id)
    def balance = @balance ||= account.current_balance
    def equity = balance.equity
    def rule_band = defined?(@rule_band) ? @rule_band : (@rule_band = RiskRule.rebalance_band)

    # The latest positions run must have started after the close and succeeded whole: a partial run keeps
    # yesterday's rows for what it could not map, and one begun before the close read the session's prices.
    def stale_inputs
      closed_at = day.regular_closes_at
      run = SyncRun.for(:positions, account).where(started_at: closed_at..).recent_first.first
      problems = []
      problems << "no rebalance_band rule" unless rule_band
      problems << "balance not synced since the close" unless balance && balance.as_of >= closed_at
      problems << "no positive equity" unless balance&.equity&.positive?
      problems << "positions not synced since the close" if run.nil?
      problems << "positions sync since the close #{run.status}" if run && !run.succeeded?
      problems
    end

    def unpriced_inputs
      closes # fetched once; a failed fetch is the one reason, not a missing quote per symbol
      return [ @quote_failure ] if @quote_failure
      covered.filter_map do |instrument|
        next "#{instrument.symbol} delisted" if instrument.delisted?
        position = positions[instrument.id]
        next "#{instrument.symbol} unpriced" if position && (!position.last_price&.positive? || position.market_value.nil?)
        "#{instrument.symbol} has no fresh quote" if position.nil? && !closes[instrument.id]&.positive?
      end
    end

    # Every instrument a target covers: its own instrument, or each held member of its class.
    def covered = targets.flat_map { |target| target.instrument ? [ target.instrument ] : members(target).map(&:instrument) }.uniq

    def members(target)
      own = targets.filter_map(&:instrument_id)
      positions.values.select { |position| position.instrument.asset_class == target.asset_class && own.exclude?(position.instrument_id) }
    end

    # A held instrument is priced by its position, so the close and the market value behind the weight agree; an
    # unheld one by its last print, fetched once for all of them. A failed fetch is a reason, not a crash.
    def closes
      @closes ||= begin
        held = positions.transform_values(&:last_price)
        unheld = targets.filter_map(&:instrument).reject { |instrument| positions.key?(instrument.id) }
        held.merge(quoted(unheld))
      end
    end

    def quoted(instruments)
      return {} if instruments.empty?
      quotes = Agent::MarketData.quotes(instruments.map(&:symbol))[:quotes].reject { |quote| quote[:stale] }.index_by { |quote| quote[:symbol] }
      instruments.to_h { |instrument| [ instrument.id, quotes.dig(instrument.symbol, :last) ] }.compact
    rescue Schwab::Error => e
      @quote_failure = "quotes unavailable (#{e.message.truncate(80)})"
      {}
    end

    def judge(target)
      if target.instrument
        close = closes.fetch(target.instrument_id)
        market_value = positions[target.instrument_id]&.market_value || 0
        one_share = close / equity
        line(target, market_value: market_value, close: close, band: [ rule_band, one_share ].max, detail: { "one_share" => one_share.round(6).to_s })
      else # a class has no single close, so its band is the rule's alone and nothing sizes it in shares
        held = members(target)
        line(target, market_value: held.sum(&:market_value), close: nil, band: rule_band, detail: { "members" => held.map { |p| p.instrument.symbol }.sort })
      end
    end

    # Judged on the stored precision, so the band preview re-judging a row agrees with the row.
    def line(target, market_value:, close:, band:, detail:)
      weight = (market_value / equity).round(6)
      drift = weight - target.target_weight
      band = band.round(6)
      notional = ((target.target_weight - weight) * equity).round(2)
      quantity = close && (notional.abs / close).floor
      quantity = [ quantity, positions[target.instrument_id]&.quantity.to_i ].min if quantity && notional.negative? # never sell more than is held
      outside = drift.abs > band # never under one whole share for an instrument: the band is at least one share wide
      Line.new(target: target, weight: weight, close: close, band: band, drift: drift, notional: notional, quantity: quantity,
               action: outside ? "reported" : "none", detail: detail)
    end

    def unavailable(target, problems)
      Line.new(target: target, weight: nil, close: nil, band: nil, drift: nil, notional: nil, quantity: nil, action: "unavailable", detail: { "reasons" => problems })
    end
end
