# What a trade paid against what was seen (docs/phase-2.6-plan.md §0.8), per leg, from the journal's own legs, and
# only for a trade that came from a proposal (a stop typed in at review is not a plan). The initial entry's fill is
# measured against the mid frozen at approval; a stop-out's fills against the stop that triggered, the stop order's
# own price, which needs no quote. Each leg is tagged:
# - comparable: a marketable entry (its limit at or above the ask) approved on a live quote and filled in that
#   session, so fill less mid is the spread and impact paid; or a stop that triggered, so fill less stop is the gap;
# - shadow: placed by hand, so the gap is the operator's delay, not the market's cost;
# - not_comparable: a resting limit, a stale quote, or a later session, where the gap is the market's drift;
# - unavailable: no quote, no bid and ask, no stop price on the order.
# Realized R is already net of everything paid (fees included); gross R adds back only the comparable slippage, and
# only on a trade whose entry is comparable, so every trade with a gross R measured the same thing. A positive cost
# is money lost to the fill.
class Trade::Costs
  def initialize(trade, ledger)
    @trade, @ledger, @proposal = trade, ledger, trade.order_proposal
    @entry, @stop = (@proposal ? [ entry_cost, stop_cost ] : [ nil, nil ])
  end

  def slippage = { "entry" => @entry, "stop" => @stop }.compact.presence

  def gross_r
    return nil unless @trade.realized_r && comparable?(@entry)
    (@trade.realized_r + [ @entry, @stop ].select { comparable?(it) }.sum { BigDecimal(it["r"]) }).round(4)
  end

  private
    def comparable?(cost) = cost && cost["tag"] == "comparable" && cost["r"]

    def entry_cost
      quote = @proposal.quote_at_approval or return nil
      fills = @ledger.initial_entry_legs.select(&:price)
      return nil if fills.empty?
      return { "tag" => "unavailable", "reason" => quote["unavailable"] } if quote["unavailable"]
      mid = mid_of(quote) or return { "tag" => "unavailable", "reason" => "no bid and ask, and no mark" }
      quantity = fills.sum(&:quantity)
      fill = fills.sum { it.quantity * it.price } / quantity
      cost(fill - mid, quantity, tag: entry_tag(fills, quote), mid: mid, fill: fill)
    end

    # Every fill of the order that closed the trade, against that order's stop, in original-entry units.
    def stop_cost
      closing = @ledger.closing_leg
      return nil unless @trade.stopped_out && closing&.activity
      order = closing.activity.order
      return { "tag" => "unavailable", "reason" => "the stop order carries no stop price" } unless order&.stop_price
      fills = @ledger.exit_legs.select { it.activity&.broker_order_id == closing.activity.broker_order_id && it.price }
      quantity = fills.sum(&:quantity)
      fill = fills.sum { it.quantity * it.price } / quantity
      cost((order.stop_price - fill) * @ledger.ratio, quantity / @ledger.ratio, tag: @proposal.shadow? ? "shadow" : "comparable", stop: order.stop_price, fill: fill)
    end

    def entry_tag(fills, quote)
      return "shadow" if @proposal.shadow?
      ask = BigDecimal(quote["ask"].to_s, exception: false)
      return "not_comparable" if quote["stale"] || ask.nil? || @proposal.limit_price < ask # a resting limit fills on the market's move
      approved_on = @proposal.decided_at&.in_time_zone(MarketDay::ZONE)&.to_date
      fills.all? { it.executed_at&.in_time_zone(MarketDay::ZONE)&.to_date == approved_on } ? "comparable" : "not_comparable"
    end

    # Per share in original-entry units, so it lines up with initial_risk.
    def cost(per_share, quantity, tag:, **seen)
      dollars = per_share * quantity
      { "tag" => tag, "per_share" => per_share.round(4).to_s, "dollars" => dollars.round(2).to_s,
        "r" => @trade.initial_risk&.positive? ? (dollars / @trade.initial_risk).round(4).to_s : nil, **seen.transform_values { it.round(4).to_s } }.compact
    end

    def mid_of(quote)
      bid, ask = BigDecimal(quote["bid"].to_s, exception: false), BigDecimal(quote["ask"].to_s, exception: false)
      return (bid + ask) / 2 if bid&.positive? && ask&.positive? && ask >= bid
      BigDecimal(quote["mark"].to_s, exception: false)&.then { it.positive? ? it : nil }
    end
end
