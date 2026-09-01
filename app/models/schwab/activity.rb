module Schwab
  # One transaction activity. The primary security transfer item gives instrument, quantity, and price
  # (trades only; on a dividend the item's amount is dollars); fee items are summed; every security item
  # is kept in `securities` because a CUSIP succession arrives as two of them in one activity.
  # Sign conventions are SCHWAB_SHAPE_UNVERIFIED; side prefers positionEffect, then the sign of netAmount.
  class Activity < Data.define(:activity_id, :type, :activity_type, :status, :sub_account, :description, :order_id,
                               :net_amount, :trade_date, :settlement_date, :executed_at, :instrument, :securities, :quantity, :price,
                               :position_effect, :commission, :fees, :raw)
    Security = Data.define(:instrument, :amount, :cost, :price, :position_effect)

    # The transaction types a cash account produces; one request each. SCHWAB_SHAPE_UNVERIFIED.
    CASH_ACCOUNT_TYPES = %w[ TRADE RECEIVE_AND_DELIVER DIVIDEND_OR_INTEREST ELECTRONIC_FUND ACH_RECEIPT ACH_DISBURSEMENT WIRE_IN WIRE_OUT
                             JOURNAL CASH_RECEIPT CASH_DISBURSEMENT MONEY_MARKET ].freeze
    VALID = "VALID"
    CASH_MOVEMENT_TYPES = %w[ ELECTRONIC_FUND ACH_RECEIPT ACH_DISBURSEMENT WIRE_IN WIRE_OUT CASH_RECEIPT CASH_DISBURSEMENT ].freeze

    def self.from(raw)
      activity_id = raw.fetch("activityId") { raise MappingError, "activity without activityId" }.to_s
      items = Array(raw["transferItems"])
      securities = items.select { |i| i["feeType"].blank? && !(InstrumentRef.from(i["instrument"])&.currency?) }
        .map { |i| Security.new(instrument: InstrumentRef.from(i["instrument"]), amount: Decimal.parse(i["amount"]), cost: Decimal.parse(i["cost"]),
                                price: Decimal.parse(i["price"]), position_effect: i["positionEffect"]) }
      fee_items = items.select { |i| i["feeType"].present? }
      executed_at = Timestamp.parse(raw["time"]) || Timestamp.parse(raw["tradeDate"]) or raise MappingError, "activity #{activity_id} has no time or tradeDate"
      primary = securities.first
      trade = raw["type"] == "TRADE"

      new(activity_id: activity_id, type: raw["type"], activity_type: raw["activityType"], status: raw["status"],
          sub_account: raw["subAccount"], description: raw["description"], order_id: raw["orderId"]&.to_s,
          net_amount: Decimal.parse(raw["netAmount"]),
          trade_date: Timestamp.parse_date(raw["tradeDate"]), settlement_date: Timestamp.parse_date(raw["settlementDate"]),
          executed_at: executed_at,
          instrument: primary&.instrument, securities: securities,
          quantity: trade ? primary&.amount&.abs : nil,
          price: trade ? primary&.price : nil,
          position_effect: primary&.position_effect,
          commission: fee_items.select { |i| i["feeType"] == "COMMISSION" }.sum(Decimal::ZERO) { |i| Decimal.parse_or_zero(i["amount"]).abs },
          fees: fee_items.reject { |i| i["feeType"] == "COMMISSION" }.sum(Decimal::ZERO) { |i| Decimal.parse_or_zero(i["amount"]).abs },
          raw: raw)
    end

    def trade? = type == "TRADE"
    def valid? = status.nil? || status == "VALID"

    # The app's classification of this activity. :other is never a quiet success; the sync counts it.
    def kind
      return :fee if fee_only?
      cash_equivalent = instrument&.asset_type == "CASH_EQUIVALENT"
      case type
      when "TRADE" then cash_equivalent ? :sweep : :fill
      when "MONEY_MARKET" then :sweep
      when "DIVIDEND_OR_INTEREST" then instrument && !cash_equivalent ? :dividend : :interest
      when *CASH_MOVEMENT_TYPES then net_amount&.negative? ? :withdrawal : :deposit
      when "JOURNAL", "RECEIVE_AND_DELIVER"
        if securities.size >= 2 then :corporate_action
        elsif securities.one? then :transfer
        elsif type == "JOURNAL" then net_amount&.negative? ? :withdrawal : :deposit
        else :other
        end
      else :other
      end
    end
    def fee_only? = raw.fetch("transferItems", []).then { |items| items.any? && items.all? { |i| i["feeType"].present? } }

    # What the sync records about an activity it could not classify.
    def summary = { type: type, activity_type: activity_type, sub_account: sub_account, description: description, net_amount: net_amount&.to_s }

    def side
      return nil unless trade?
      case position_effect
      when "OPENING" then "BUY"
      when "CLOSING" then "SELL"
      else net_amount&.negative? ? "BUY" : (net_amount ? "SELL" : nil)
      end
    end
  end
end
