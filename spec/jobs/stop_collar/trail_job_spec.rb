require "rails_helper"

RSpec.describe StopCollar::TrailJob do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:stop) { create(:order, :working_stop, account: account, instrument: xyz, stop_price: 40, quantity: 10, remaining_quantity: 10) }
  let!(:position) { create(:position, account: account, instrument: xyz, quantity: 10, last_price: 60, working_stop_order: stop) }

  it "keeps the tightest trail between the working stop and the close as a stamped suggestion, and clears it when nothing is tighter" do
    script_price_history(close: 60, range: 1)
    described_class.perform_now
    expect(position.reload.suggested_stop).to be > 40
    expect(position.suggested_stop).to be < 60
    expect(position.suggested_stop_method).to be_in(%w[ chandelier atr ])
    expect(position.suggested_at).to be_present
    expect(position.stop_suggestion).to eq(position.suggested_stop)

    stop.update!(stop_price: 59.9)
    expect(position.reload.stop_suggestion).to be_nil # re-checked at read time: the stop moved above the trail
    described_class.perform_now
    expect(position.reload.suggested_stop).to be_nil
  end

  it "suggests nothing for a position with no working stop, a delisted holding, thin data, or a closed day" do
    script_price_history(close: 60, range: 1)
    naked = create(:position, account: account, instrument: create(:instrument, symbol: "NAKED", cusip: "111111111"), quantity: 5, last_price: 60)
    described_class.perform_now
    expect(naked.reload.suggested_stop).to be_nil
    xyz.update!(delisted_at: Time.current)
    described_class.perform_now
    expect(position.reload.suggested_stop).to be_nil

    xyz.update!(delisted_at: nil)
    Rails.cache.clear
    Schwab::FakeClient.instance.reset! # the shipped two-candle fixture
    described_class.perform_now
    expect(position.reload.suggested_stop).to be_nil

    Schwab::FakeClient.instance.close_market_on(MarketDay.today + 3)
    script_price_history(close: 60, range: 1)
    expect { described_class.perform_now(MarketDay.today + 3) }.not_to change { Schwab::FakeClient.instance.calls.count { |c| c.first == :price_history } }
  end

  it "stops on a spent Schwab budget and leaves yesterday's suggestion to age out rather than wiping it" do
    position.update!(suggested_stop: 45, suggested_stop_method: "atr", suggested_at: 20.hours.ago)
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { raise Schwab::RateLimited.new("busy", retry_after: 30) }
    expect { described_class.perform_now }.not_to raise_error
    expect(position.reload.suggested_stop).to eq(45)
    expect(position.stop_suggestion).to eq(45)
    travel 3.days
    expect(position.stop_suggestion).to be_nil # aged out
  end
end
