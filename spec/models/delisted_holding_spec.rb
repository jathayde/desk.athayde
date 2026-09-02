require "rails_helper"

RSpec.describe "A delisted holding" do
  let!(:account) { create(:account) }
  let(:instrument) { create(:instrument, symbol: "GONE") }
  let(:user) { create(:user, email_address: "john@athayde.com") }

  it "leaves the unprotected count and the risk sums, sorts last, and is named once on the dashboard" do
    create(:schwab_token)
    create(:balance, account: account, equity: 6500)
    create(:position, account: account, instrument: instrument, quantity: 10, last_price: nil, market_value: nil)
    live = create(:instrument, symbol: "LIVE")
    create(:position, account: account, instrument: live, quantity: 10, last_price: 20, market_value: 200)
    instrument.delist!(user: user)
    instrument.delist!(user: user) # idempotent: one audit row
    expect(instrument.reload).to be_delisted
    expect(AuditEvent.where(kind: "instrument_delisted", subject: instrument).count).to eq(1)

    dashboard = Desk.new
    expect(dashboard.rows.map { |r| [ r.position.instrument.symbol, r.protection ] }).to eq([ [ "LIVE", :unprotected ], [ "GONE", :delisted ] ])
    expect(dashboard.excluded_by_reason).to eq(unprotected: 1, delisted: 1)
    expect(Snapshot.risk_now(account, BigDecimal("6500"))).to include(unprotected_count: 1)
    expect(Agent::Tools.call("get_portfolio", {}, transport: :scheduled).value["positions"].find { |p| p["symbol"] == "GONE" }).to include("protection" => "delisted")
    expect(Agent::Context.new(kind: :morning_brief, date: MarketDay.today).system_prompt).to include("Delisted holdings", "GONE")
  end

  it "stays delisted while Schwab repeats the stale mark, and comes back only on a different positive price" do
    account.update!(schwab_hash: Schwab::FakeClient::ACCOUNT_HASH)
    create(:schwab_token)
    Sync::PositionsJob.perform_now(account)
    xyz = Instrument.find_by!(symbol: "XYZ")
    xyz.delist!(user: user, price: account.positions.find_by!(instrument: xyz).last_price)
    Sync::PositionsJob.perform_now(account)
    expect(xyz.reload).to be_delisted # the fixture repeats the same market value

    Schwab::FakeClient.instance.enqueue(:account) do
      raw = schwab_fixture("account")
      raw["securitiesAccount"]["positions"].find { |p| p["instrument"]["symbol"] == "XYZ" }["marketValue"] = 2200.0
      raw
    end
    Sync::PositionsJob.perform_now(account)
    expect(xyz.reload).not_to be_delisted
    expect(AuditEvent.where(kind: "instrument_relisted", subject: xyz).last).to have_attributes(actor: "system", reason: a_string_starting_with("Schwab priced it again at"))
  end

  it "carries no market numbers for a delisted row in get_portfolio, and names only held delisted symbols in the prompt" do
    create(:schwab_token)
    create(:balance, account: account, equity: 6500)
    create(:position, account: account, instrument: instrument, quantity: 10, last_price: 3, market_value: 30)
    instrument.delist!(user: user, price: 3)
    sold = create(:instrument, symbol: "SOLD")
    sold.delist!(user: user)
    row = Agent::Tools.call("get_portfolio", {}, transport: :scheduled).value["positions"].find { |p| p["symbol"] == "GONE" }
    expect(row).to include("protection" => "delisted", "last_price" => nil, "market_value" => nil, "unrealized_pnl" => nil)
    prompt = Agent::Context.new(kind: :morning_brief, date: MarketDay.today).system_prompt
    expect(prompt).to include("GONE")
    expect(prompt).not_to include("SOLD")
  end
end
