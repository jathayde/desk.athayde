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

    # The account-level payload without the positions array, which is large and lives on the position rows.
    def raw_without_positions = raw.deep_dup.tap { |r| r["securitiesAccount"]&.delete("positions") }
  end
end
