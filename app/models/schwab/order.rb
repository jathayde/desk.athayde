module Schwab
  # One order as Schwab returns it. Bracket children and replacements arrive nested; #flatten walks them.
  # Container strategies (OCO, TRIGGER parents) can have no legs, so instrument may be nil.
  class Order < Data.define(:order_id, :status, :order_type, :session, :duration, :strategy_type, :instruction, :quantity,
                            :filled_quantity, :remaining_quantity, :price, :stop_price, :tax_lot_method, :entered_at,
                            :close_time, :instrument, :children, :replacements, :parent_order_id, :replaces_order_id, :raw)
    # SCHWAB_SHAPE_UNVERIFIED: see docs/schwab-api-contract.md for the status and type vocabularies.
    WORKING_STATUSES = %w[ WORKING ACCEPTED QUEUED PENDING_ACTIVATION AWAITING_PARENT_ORDER AWAITING_STOP_CONDITION
                           AWAITING_CONDITION NEW AWAITING_RELEASE_TIME ].freeze
    LIVE_STATUSES = %w[ WORKING ACCEPTED QUEUED PENDING_ACTIVATION ].freeze # in the market, not awaiting a parent or condition
    STOP_TYPES = %w[ STOP STOP_LIMIT TRAILING_STOP TRAILING_STOP_LIMIT ].freeze
    WORKING = "WORKING"
    SELL = "SELL"
    BUY = "BUY"
    GONE = "UNKNOWN_TO_SCHWAB" # local sentinel: Schwab no longer returns this order by id

    def self.from(raw, parent_order_id: nil, replaces_order_id: nil)
      leg = Array(raw["orderLegCollection"]).first || {}
      order_id = raw.fetch("orderId") { raise MappingError, "order without orderId" }.to_s
      new(order_id: order_id, status: raw["status"], order_type: raw["orderType"], session: raw["session"],
          duration: raw["duration"], strategy_type: raw["orderStrategyType"], instruction: leg["instruction"],
          quantity: Decimal.parse(raw["quantity"]) || Decimal.parse(leg["quantity"]),
          filled_quantity: Decimal.parse(raw["filledQuantity"]), remaining_quantity: Decimal.parse(raw["remainingQuantity"]),
          price: Decimal.parse(raw["price"]), stop_price: Decimal.parse(raw["stopPrice"]), tax_lot_method: raw["taxLotMethod"],
          entered_at: Timestamp.parse(raw["enteredTime"]), close_time: Timestamp.parse(raw["closeTime"]),
          instrument: InstrumentRef.from(leg["instrument"]),
          children: Array(raw["childOrderStrategies"]).map { |c| from(c, parent_order_id: order_id) },
          replacements: Array(raw["replacingOrderCollection"]).map { |r| from(r, parent_order_id: parent_order_id, replaces_order_id: order_id) },
          parent_order_id: parent_order_id, replaces_order_id: replaces_order_id, raw: raw)
    end

    # Self plus every nested child and replacement, depth first, lineage already stamped.
    def flatten = [ self, *children.flat_map(&:flatten), *replacements.flat_map(&:flatten) ]

    def side
      case instruction
      when /\ABUY/ then "BUY"
      when /\ASELL/ then "SELL"
      end
    end

    def container? = instrument.nil?
    def working? = WORKING_STATUSES.include?(status)
    def stop? = STOP_TYPES.include?(order_type)
  end
end
