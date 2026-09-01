require "rails_helper"

# The kickoff's isolation rule: every Schwab shape assumption lives in the adapter layer.
RSpec.describe "Schwab shape isolation" do
  let(:schwab_names) do
    %w[ hashValue securitiesAccount longQuantity averagePrice marketValue orderLegCollection childOrderStrategies replacingOrderCollection
        transferItems sessionHours activityId enteredTime cashAvailableForTrading liquidationValue netAmount stopPrice orderType
        instrumentId assetType isOpen lastPrice invalidSymbols candles AWAITING_PARENT_ORDER STOP_LIMIT RECEIVE_AND_DELIVER ]
  end

  let(:quoted_literals) { %w[ WORKING VALID SELL BUY FILLED CASH_EQUIVALENT ].map { |v| %("#{v}") } }

  it "keeps Schwab field names and enum values inside the Schwab namespace and its fixtures" do
    files = Rails.root.glob("{app,lib,db/seeds.rb,config/recurring.yml}/**/*.{rb,erb,yml}") + [ Rails.root.join("db/seeds.rb") ]
    offenders = files.uniq.reject { |f| f.to_s.include?("/app/models/schwab/") || f.to_s.end_with?("/app/models/schwab.rb") }
      .select { |f| f.file? && (schwab_names + quoted_literals).any? { |name| f.read.include?(name) } }
    expect(offenders).to be_empty
  end
end
