module Schwab
  # GET /accounts/{hash}?fields=positions, mapped.
  AccountSummary = Data.define(:account_type, :positions, :balances, :raw) do
    def self.from(raw)
      account = raw.fetch("securitiesAccount") { raise MappingError, "securitiesAccount missing" }
      new(account_type: account["type"],
          positions: Array(account["positions"]).map { |p| Position.from(p) },
          balances: Balances.from(account["currentBalances"]),
          raw: raw)
    end
  end
end
