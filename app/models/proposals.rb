# Drafting proposals, shared by the tool, the form, and the hypothetical evaluation.
module Proposals
  class Error < StandardError; end
  class UnknownSymbol < Error; end

  # An unsaved proposal with its instrument resolved and, for an entry, its sizing and collar frozen from a
  # year of candles and a fresh quote: the shape both the hypothetical tool and Proposals::Create start from.
  # The allocation jobs pass the target's instrument row, never a symbol to re-resolve (CUSIP identity), and an
  # expiry past the next session, since they propose after the close.
  def self.draft(account:, kind:, side:, limit_price:, symbol: nil, instrument: nil, stop_price: nil, setup: nil, thesis: nil, origin:, user: nil, quantity: nil,
                 tax_lot_method: nil, expires_at: nil, allocation_source: nil)
    instrument ||= Instrument.find_by(symbol: symbol.to_s.strip.upcase) or raise UnknownSymbol, "unknown symbol #{symbol}"
    proposal = OrderProposal.new(account: account, instrument: instrument, kind: kind, side: side, order_type: Schwab::Order::LIMIT, limit_price: limit_price, stop_price: stop_price,
                                 planned_stop: stop_price, setup: setup, thesis: thesis, origin: origin, user: user, quantity: quantity,
                                 expires_at: expires_at || MarketDay.today.in_time_zone(MarketDay::ZONE).end_of_day, allocation_source: allocation_source)
    method = proposal.tax_lot_method = tax_lot_method.presence || Schwab::Order::DEFAULT_TAX_LOT_METHOD if proposal.reduces_position?
    raise Error, "unknown lot method #{method}" if method && !Schwab::Order::TAX_LOT_METHODS.include?(method)
    if proposal.kind_entry?
      proposal.collar = StopCollar::Calculator.new(instrument, entry_price: limit_price, params: RiskRule.params_for("stop_collar", setup: setup)).call.to_h
      sizing = Sizing.for_proposal(proposal)
      proposal.sizing = sizing.to_h
      proposal.quantity = sizing.quantity
    else
      proposal.quantity ||= account.positions.find_by(instrument: instrument)&.quantity
      proposal.lots = Proposals::Lots.for(account.trades.open.find_by(instrument: instrument), quantity: proposal.quantity.to_d, method: method) if proposal.reduces_position?
    end
    proposal
  end
end
