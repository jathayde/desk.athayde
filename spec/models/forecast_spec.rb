require "rails_helper"

RSpec.describe Forecast do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  before { ready_desk(account) }

  def propose = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, target_price: 56, thesis: "t", origin: :human, user: john)
  def forecast_on(proposal, **) = described_class.record!(proposal, author: :human, user: john, probability: "0.4", horizon_days: 10, **)

  it "starts on the session whose candle holds nothing from before it was made, a closed day included" do
    zone = Time.find_zone!(MarketDay::ZONE)
    monday = Date.new(2026, 10, 5)
    expect(described_class.starts_on(zone.local(2026, 10, 5, 9, 29))).to eq(monday)
    expect(described_class.starts_on(zone.local(2026, 10, 5, 9, 30))).to eq(monday + 1)
    expect(described_class.starts_on(zone.local(2026, 10, 5, 20))).to eq(monday + 1)
    MarketDay.create!(date: monday - 2, trading: false, source: :schwab, fetched_at: Time.current) # a Saturday's row has no open
    expect(described_class.starts_on(zone.local(2026, 10, 3, 12))).to eq(monday - 2)
  end

  # Each refusal in a savepoint, so the next statement runs in a usable transaction.
  def refused(message, &write) = expect { described_class.transaction(requires_new: true, &write) }.to raise_error(ActiveRecord::StatementInvalid, message)

  it "is frozen by the database: the claim always, the outcome once written, and never deleted" do
    forecast = forecast_on(propose)
    refused(/claim is frozen/) { described_class.where(id: forecast).update_all(probability: 0.9) }
    refused(/claim is frozen/) { described_class.where(id: forecast).update_all(target_price: 60) }
    forecast.update!(checked_through: MarketDay.today) # the resolver's progress while open
    forecast.update!(outcome: "hit", resolved_at: Time.current)
    refused(/resolved forecast is frozen/) { described_class.where(id: forecast).update_all(outcome: "miss") }
    refused(/never deleted/) { described_class.where(id: forecast).delete_all }
  end

  it "refuses what it cannot measure: an exit, a proposal without a target, a probability or horizon out of range, a second by the same author" do
    proposal = propose
    expect { forecast_on(proposal, probability: "1") }.to raise_error(ArgumentError, /between 0 and 1/)
    expect { forecast_on(proposal, probability: "0.99999") }.to raise_error(ArgumentError, /between 0 and 1/) # validated as it would be stored
    expect { forecast_on(proposal, horizon_days: "61") }.to raise_error(ArgumentError, /1 to 60 sessions/)
    forecast_on(proposal)
    expect { forecast_on(proposal) }.to raise_error(ActiveRecord::RecordNotUnique)
    proposal.reject!(user: john, reason: "no")
    untargeted = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :human, user: john)
    expect { forecast_on(untargeted) }.to raise_error(Forecast::Unmeasurable, /no stop and target/)
  end
end
