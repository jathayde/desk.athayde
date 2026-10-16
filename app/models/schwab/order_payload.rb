module Schwab
  # The order bodies the app sends (docs/phase-2-plan.md §0.5). Every Schwab field name lives here.
  # SCHWAB_SHAPE_UNVERIFIED: the TRIGGER strategy, the child shape, and taxLotMethod are modelled on schwab-py's
  # order builder and are confirmed only by a shadowed payload compared against an order placed by hand.
  module OrderPayload
    NORMAL = "NORMAL"
    DAY = "DAY"
    GOOD_TILL_CANCEL = "GOOD_TILL_CANCEL"
    SINGLE = "SINGLE"
    TRIGGER = "TRIGGER"
    STOP = "STOP"

    # A LIMIT entry whose child is a STOP sell of the same quantity, good until cancelled.
    def self.bracket(symbol:, quantity:, limit_price:, stop_price:)
      leg(BUY, symbol, quantity).merge(
        "orderType" => Order::LIMIT, "price" => price(limit_price), "orderStrategyType" => TRIGGER,
        "childOrderStrategies" => [ leg(SELL, symbol, quantity).merge("orderType" => STOP, "stopPrice" => price(stop_price), "duration" => GOOD_TILL_CANCEL, "orderStrategyType" => SINGLE) ]
      )
    end

    # A plain LIMIT buy with no child: a rebalance toward a target, which carries no stop.
    def self.buy(symbol:, quantity:, limit_price:)
      leg(BUY, symbol, quantity).merge("orderType" => Order::LIMIT, "price" => price(limit_price), "orderStrategyType" => SINGLE)
    end

    def self.sell(symbol:, quantity:, limit_price:, tax_lot_method: nil)
      leg(SELL, symbol, quantity).merge("orderType" => Order::LIMIT, "price" => price(limit_price), "orderStrategyType" => SINGLE)
                                 .merge(tax_lot_method ? { "taxLotMethod" => tax_lot_method } : {})
    end

    # A standalone STOP sell, good until cancelled: the replacement for a bracket child after a partial exit.
    def self.stop(symbol:, quantity:, stop_price:)
      leg(SELL, symbol, quantity).merge("orderType" => STOP, "stopPrice" => price(stop_price), "duration" => GOOD_TILL_CANCEL, "orderStrategyType" => SINGLE)
    end

    def self.leg(instruction, symbol, quantity)
      { "session" => NORMAL, "duration" => DAY,
        "orderLegCollection" => [ { "instruction" => instruction, "quantity" => quantity.to_i, "instrument" => { "symbol" => symbol, "assetType" => "EQUITY" } } ] }
    end

    def self.price(value) = format("%.2f", BigDecimal(value.to_s).round(2)) # two decimals, as schwab-py sends them

    BUY = Order::BUY
    SELL = Order::SELL
  end
end
