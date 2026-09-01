module Schwab
  # currentBalances for a cash account. settled_cash is derived, not a Schwab field; see the contract.
  Balances = Data.define(:equity, :cash_available_for_trading, :cash_available_for_withdrawal, :unsettled_cash,
                         :total_cash, :cash_balance, :buying_power, :raw) do
    def self.from(raw)
      raw ||= {}
      new(equity: Decimal.parse(raw["liquidationValue"]),
          cash_available_for_trading: Decimal.parse(raw["cashAvailableForTrading"]),
          cash_available_for_withdrawal: Decimal.parse(raw["cashAvailableForWithdrawal"]),
          unsettled_cash: Decimal.parse(raw["unsettledCash"]),
          total_cash: Decimal.parse(raw["totalCash"]),
          cash_balance: Decimal.parse(raw["cashBalance"]),
          buying_power: Decimal.parse(raw["buyingPower"]),
          raw: raw)
    end

    # Reading A: available for trading minus unsettled. Reading B: available for withdrawal.
    # Conservative: the smaller of the two when both are present. SCHWAB_SHAPE_UNVERIFIED.
    def settled_cash
      [ settled_cash_by_subtraction, cash_available_for_withdrawal ].compact.min
    end

    def settled_cash_by_subtraction
      return nil if cash_available_for_trading.nil?
      cash_available_for_trading - (unsettled_cash || 0)
    end
  end
end
