# Drafting proposals, shared by the tool, the form, and the hypothetical evaluation.
module Proposals
  FORM_FIELDS = %i[ kind symbol limit_price stop_price target_price probability horizon_days quantity setup_id thesis tax_lot_method ].freeze

  class Error < StandardError; end
  class UnknownSymbol < Error; end

  # An unsaved proposal with its instrument resolved and, for an entry, its sizing and collar frozen from a
  # year of candles and a fresh quote: the shape both the hypothetical tool and Proposals::Create start from.
  # The allocation jobs pass the target's instrument row, never a symbol to re-resolve (CUSIP identity), and an
  # expiry past the next session, since they propose after the close.
  def self.draft(account:, kind:, side:, limit_price:, symbol: nil, instrument: nil, stop_price: nil, target_price: nil, setup: nil, thesis: nil, origin:, user: nil, quantity: nil,
                 tax_lot_method: nil, expires_at: nil, allocation_source: nil, context: {})
    instrument ||= Instrument.find_by(symbol: symbol.to_s.strip.upcase) or raise UnknownSymbol, "unknown symbol #{symbol}"
    proposal = OrderProposal.new(account: account, instrument: instrument, kind: kind, side: side, order_type: Schwab::Order::LIMIT, limit_price: limit_price, stop_price: stop_price,
                                 target_price: target_price, planned_stop: stop_price, setup: setup, thesis: thesis, origin: origin, user: user, quantity: quantity,
                                 expires_at: expires_at || MarketDay.today.in_time_zone(MarketDay::ZONE).end_of_day, allocation_source: allocation_source, context: context)
    method = proposal.tax_lot_method = tax_lot_method.presence || Schwab::Order::DEFAULT_TAX_LOT_METHOD if proposal.reduces_position?
    raise Error, "unknown lot method #{method}" if method && !Schwab::Order::TAX_LOT_METHODS.include?(method)
    if proposal.kind_entry?
      proposal.collar = StopCollar::Calculator.new(instrument, entry_price: limit_price, params: RiskRule.params_for("stop_collar", setup: setup)).call.to_h
      sizing = Sizing.for_proposal(proposal)
      proposal.sizing = sizing.to_h
      proposal.quantity = sizing.quantity
      proposal.reference_close, proposal.reference_on, proposal.reference_volatility = reference(instrument)
    else
      proposal.quantity ||= account.positions.find_by(instrument: instrument)&.quantity
      proposal.lots = Proposals::Lots.for(account.trades.open.find_by(instrument: instrument), quantity: proposal.quantity.to_d, method: method) if proposal.reduces_position?
    end
    proposal
  end

  VOLATILITY_RETURNS = 20

  # The last final close, which every forecast on an entry is measured from (docs/phase-2.6-plan.md §0.1), and the
  # daily volatility up to it, the standard deviation of the last 20 daily log returns, which the calibration
  # baseline needs (§0.3): never today's partial bar. The collar has just read the same history, so this is the tool
  # cache's copy. Nils when the history cannot say (stale, or under the collar's 30 candles, which bars a new
  # listing), and then no forecast can be made on it.
  def self.reference(instrument)
    final = StopCollar::Candles.for(instrument).final
    return [ nil, nil, nil ] if final.empty?
    [ final.last[:close], final.last[:date].to_date, volatility(final.last(VOLATILITY_RETURNS + 1).map { it[:close] }) ]
  rescue StopCollar::Candles::Refused, Schwab::Error
    [ nil, nil, nil ]
  end

  def self.volatility(closes)
    returns = closes.each_cons(2).map { |prev, close| Math.log(close / prev) }
    return nil if returns.size < VOLATILITY_RETURNS
    mean = returns.sum / returns.size
    BigDecimal(Math.sqrt(returns.sum { (it - mean)**2 } / (returns.size - 1)), 6).round(6).nonzero?
  end
end
