require "rails_helper"

RSpec.describe Schwab::FakeClient do
  subject(:fake) { described_class.instance }

  it "exposes exactly the real client's public interface, parameters included" do
    real = Schwab::Client.public_instance_methods(false)
    expect(described_class.public_instance_methods(false) - %i[ reset! enqueue close_market_on script_daily_history calls ]).to match_array(real)
    real.each do |name|
      expect(described_class.instance_method(name).parameters).to eq(Schwab::Client.instance_method(name).parameters), "parameters differ on ##{name}"
    end
  end

  it "serves raw shapes the real mappers accept, already scrubbed" do
    raw = fake.account(described_class::ACCOUNT_HASH)
    expect(raw.dig("securitiesAccount", "accountNumber")).to be_nil
    expect(Schwab::AccountSummary.from(raw).positions.size).to eq(3)
    trades = fake.transactions(described_class::ACCOUNT_HASH, from: 1.day.ago, type: "TRADE")
    expect(trades.map { |a| a["type"] }.uniq).to eq([ "TRADE" ])
    expect(Schwab::Activity.from(trades.first).side).to eq("BUY")
    expect(fake.account_numbers).to eq([ described_class::ACCOUNT_HASH ])
  end

  it "finds any order in the tree by id" do
    expect(fake.order(described_class::ACCOUNT_HASH, "1004055538201")["stopPrice"]).to eq(86.5)
    expect { fake.order(described_class::ACCOUNT_HASH, "0") }.to raise_error(Schwab::RequestError)
  end

  it "reports requested symbols it does not know as invalid" do
    batch = Schwab::Quote.batch(fake.quotes(%w[ XYZ NOPE ]))
    expect(batch.quotes.map(&:symbol)).to eq([ "XYZ" ])
    expect(batch.invalid_symbols).to eq([ "NOPE" ])
  end

  it "scripts the next response per method, or every response, and records calls" do
    fake.enqueue(:orders) { raise Schwab::RateLimited.new(retry_after: 30) }
    expect { fake.orders(described_class::ACCOUNT_HASH, from: 1.day.ago) }.to raise_error(Schwab::RateLimited)
    expect(fake.orders(described_class::ACCOUNT_HASH, from: 1.day.ago)).to be_an(Array)
    fake.enqueue(:account_numbers, sticky: true) { raise Schwab::ServerError }
    2.times { expect { fake.account_numbers }.to raise_error(Schwab::ServerError) }
    expect(fake.calls.map(&:first)).to eq(%i[ orders orders account_numbers account_numbers ])
  end

  it "closes markets on weekends and on request, with the right offset year-round" do
    expect(Schwab::MarketHours.from(fake.market_hours(Date.new(2026, 9, 5)), date: Date.new(2026, 9, 5))).not_to be_open
    summer = Schwab::MarketHours.from(fake.market_hours(Date.new(2026, 9, 8)), date: Date.new(2026, 9, 8))
    winter = Schwab::MarketHours.from(fake.market_hours(Date.new(2027, 1, 5)), date: Date.new(2027, 1, 5))
    expect(summer.regular_opens_at).to eq(Time.utc(2026, 9, 8, 13, 30))
    expect(winter.regular_opens_at).to eq(Time.utc(2027, 1, 5, 14, 30))
    fake.close_market_on(Date.new(2026, 9, 8))
    expect(Schwab::MarketHours.from(fake.market_hours(Date.new(2026, 9, 8)), date: Date.new(2026, 9, 8))).not_to be_open
  end

  it "scripts auth: the fake code exchanges, anything else needs re-auth" do
    expect(fake.exchange_code(described_class::FAKE_CODE)).to include("access_token")
    expect { fake.exchange_code("bogus") }.to raise_error(Schwab::ReauthRequired)
  end

  it "is what Schwab.client returns outside production" do
    expect(Schwab.client).to be(described_class.instance)
  end
end
