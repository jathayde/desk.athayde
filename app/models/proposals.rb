# Drafting proposals, shared by the tool, the form, and the hypothetical evaluation.
module Proposals
  class Error < StandardError; end
  class UnknownSymbol < Error; end

  # An unsaved proposal with its instrument resolved and, for an entry, its sizing and collar frozen from a
  # year of candles and a fresh quote: the shape both the hypothetical tool and Proposals::Create start from.
  def self.draft(account:, kind:, side:, symbol:, limit_price:, stop_price: nil, setup: nil, thesis: nil, origin:, user: nil, quantity: nil)
    instrument = Instrument.find_by(symbol: symbol.to_s.strip.upcase) or raise UnknownSymbol, "unknown symbol #{symbol}"
    proposal = OrderProposal.new(account: account, instrument: instrument, kind: kind, side: side, order_type: Schwab::Order::LIMIT, limit_price: limit_price, stop_price: stop_price,
                                 planned_stop: stop_price, setup: setup, thesis: thesis, origin: origin, user: user, quantity: quantity,
                                 expires_at: MarketDay.today.in_time_zone(MarketDay::ZONE).end_of_day)
    if proposal.kind_entry?
      desk = Desk.new(account: account)
      proposal.collar = StopCollar::Calculator.new(instrument, entry_price: limit_price, params: RiskRule.active_for("stop_collar", setup: setup)&.params || {}).call.to_h
      sizing = Sizing.for(limit_price: limit_price, stop_price: stop_price, equity: desk.balance_stale? ? nil : desk.equity, rule: RiskRule.active_for("max_risk_per_trade", setup: setup))
      proposal.sizing = sizing.to_h
      proposal.quantity = sizing.quantity
    elsif quantity.nil?
      proposal.quantity = account.positions.find_by(instrument: instrument)&.quantity
    end
    proposal
  end
end
