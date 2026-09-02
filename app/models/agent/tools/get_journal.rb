class Agent::Tools::GetJournal < Agent::Tool
  MAX_LIMIT = 100 # with legs, 200 trades sent twice (text plus structured) would pass the Claude app's result cap

  tool description: "Trades from the journal, newest first, paginated. Filter by status (open, closed), needs_review, missing_post_mortem, " \
                    "setup name, symbol, and opened/closed date ranges. Legs are included only on request. R is null when no planned stop was known at entry.",
       input: { status: { type: "string", enum: %w[ open closed ] }, needs_review: { type: "boolean" }, missing_post_mortem: { type: "boolean" },
                setup: { type: "string" }, symbol: { type: "string" }, opened_after: { type: "string", format: "date" }, closed_after: { type: "string", format: "date" },
                include_legs: { type: "boolean", default: false }, limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, default: 50 }, offset: { type: "integer", minimum: 0, default: 0 } },
       output: { trades: { type: "array", items: { type: "object" } }, total: { type: "integer" }, limit: { type: "integer" }, offset: { type: "integer" } }

  def call(status: nil, needs_review: nil, missing_post_mortem: nil, setup: nil, symbol: nil, opened_after: nil, closed_after: nil, include_legs: false, limit: 50, offset: 0)
    scope = Trade.journaled
    scope = scope.where(status: status) if status
    scope = scope.where(needs_review: needs_review) unless needs_review.nil?
    scope = scope.missing_post_mortem if missing_post_mortem
    scope = scope.in_setup(setup) if setup
    scope = scope.in_symbol(symbol) if symbol
    scope = scope.opened_after(date(opened_after)) if opened_after
    scope = scope.closed_after(date(closed_after)) if closed_after
    limit = limit.to_i.clamp(1, MAX_LIMIT)
    offset = offset.to_i.clamp(0..)
    trades = scope.newest_first.preload(:instrument, :setup).offset(offset).limit(limit)
    { total: scope.count, limit: limit, offset: offset, trades: trades.map { |t| trade(t, include_legs: include_legs) } }
  end

  private
    def date(value)
      Date.parse(value.to_s)
    rescue Date::Error
      raise InvalidArguments, "#{value.inspect} is not a date"
    end

    def trade(trade, include_legs:)
      hash = { id: trade.id, symbol: trade.instrument.symbol, cusip: trade.instrument.cusip, status: trade.status, setup: trade.setup&.name,
               opened_at: trade.opened_at, closed_at: trade.closed_at, quantity: trade.quantity, peak_quantity: trade.peak_quantity,
               avg_entry: trade.avg_entry, avg_exit: trade.avg_exit, planned_stop: trade.current_planned_stop, initial_risk: trade.initial_risk,
               realized_pnl: trade.realized_pnl, realized_r: trade.realized_r, stopped_out: trade.stopped_out?, bootstrapped: trade.bootstrapped?,
               needs_review: trade.needs_review?, review_reason: trade.review_reason, excluded_from_stats: trade.excluded_from_stats?,
               thesis: trade.thesis, post_mortem: trade.post_mortem, agent_notes: trade.agent_notes, followed_setup: trade.followed_setup }
      hash[:legs] = trade.ordered_legs.map { |l| { kind: l.kind, plug: l.plug?, quantity: l.quantity, price: l.price, ratio: l.ratio, cash_amount: l.cash_amount, executed_at: l.executed_at } } if include_legs
      hash
    end
end
