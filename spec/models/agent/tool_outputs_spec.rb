require "rails_helper"

RSpec.describe "Agent tool outputs" do
  def output(name, **args) = Agent::Tools.call(name, args, transport: :scheduled).tap { |r| expect(r.error).to be_nil }.value

  # Validates every serialized output against the schema the MCP server advertises.
  def conforming(name, **args)
    output(name, **args).tap do |value|
      MCP::Tool::OutputSchema.new(Agent::Tools.find(name, transport: :mcp).output_schema).validate_result(value)
    end
  end

  describe "over a desk synced from the fake broker" do
    let!(:token) { create(:schwab_token) }
    let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH, trading_enabled: true) }
    let(:user) { create(:user, email_address: "john@athayde.com") }

    before do
      Sync::PositionsJob.perform_now(account)
      Sync::OrdersJob.perform_now(account)
      Sync::ActivitiesJob.perform_now(account)
      Journal::BootstrapJob.perform_now(account)
      Journal::LinkFillsJob.perform_now(account)
      MarketDay.for(MarketDay.today)
      SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "x")
      AuditEvent.log("manual_halt_set", actor: :human, user: user, reason: "x")
    end

    it "get_portfolio carries protection, stamps, and never zero for unknown risk" do
      portfolio = conforming("get_portfolio")
      expect(portfolio["state"]).to eq("ready")
      xyz = portfolio["positions"].find { |p| p["symbol"] == "XYZ" }
      expect(xyz).to include("protection" => "protected", "stop_price" => "48.9", "quantity" => "40.0", "cusip" => "037833100")
      expect(xyz["as_of"]).to be_present
      expect(portfolio["open_risk"]["amount"]).to be_present
    end

    it "get_account_health reports token, sync, equity, drawdown, and the halt without naming the user" do
      health = conforming("get_account_health")
      expect(health["token"]["status"]).to eq("healthy")
      expect(health["sync"]["feeds"]["positions"]["last_success_at"]).to be_present
      expect(health["equity"]["value"]).to eq("6508.55")
      expect(health["halted"]).to be(true)
      expect(health.to_json).not_to include("john@athayde.com")
    end

    it "get_journal paginates, filters, and includes legs only on request" do
      journal = conforming("get_journal", limit: 1)
      expect(journal["total"]).to eq(2)
      expect(journal["trades"].size).to eq(1)
      expect(journal["trades"].first).not_to have_key("legs")
      with_legs = output("get_journal", symbol: "xyz", include_legs: true)
      expect(with_legs["trades"].first["legs"]).to be_an(Array)
      expect(output("get_journal", needs_review: true)["trades"].map { |t| t["needs_review"] }).to all(be(true))
      expect(output("get_journal", opened_after: "2000-01-01")["trades"]).to all(include("opened_at" => be_present))
      expect(Agent::Tools.call("get_journal", { opened_after: "yesterday-ish" }, transport: :mcp).error).to include("not a date")
    end

    it "never leaks an account hash, raw payload, account number, or email from any tool" do
      Agent::Tools.for(:mcp).each do |tool|
        args = case tool.tool_name
        when "get_quotes" then { symbols: [ "XYZ" ] }
        when "get_price_history" then { symbol: "XYZ" }
        when "get_journal" then { include_legs: true }
        else {}
        end
        text = Agent::Tools.call(tool.tool_name, args, transport: :mcp).value.to_json
        expect(text).not_to match(/[0-9A-F]{64}/i), tool.tool_name
        expect(text).not_to include("accountNumber")
        expect(text).not_to include("\"raw\"")
        expect(text).not_to include("@athayde.com")
      end
    end
  end

  describe "before the first sync" do
    it "get_portfolio and get_account_health answer with the state, conforming to their schemas" do
      expect(conforming("get_portfolio")).to include("state" => "not_connected", "positions" => [], "open_risk" => nil)
      expect(conforming("get_account_health")).to include("state" => "not_connected", "equity" => nil, "drawdown" => nil, "unprotected" => nil)
    end
  end

  describe "market data" do
    it "get_quotes returns quotes and invalid symbols, then cached values marked stale when Schwab fails" do
      quotes = conforming("get_quotes", symbols: %w[ xyz NOPE ])
      expect(quotes["quotes"].map { |q| q["symbol"] }).to eq([ "XYZ" ])
      expect(quotes["invalid_symbols"]).to eq([ "NOPE" ])
      expect(quotes["quotes"].first["stale"]).to be(false)
      travel 3.minutes
      Schwab::FakeClient.instance.enqueue(:quotes) { raise Schwab::ServerError.new("down", status: 503) }
      again = conforming("get_quotes", symbols: %w[ XYZ ABC ])
      expect(again["quotes"].first["stale"]).to be(true)
      expect(again["unavailable_symbols"]).to eq([ "ABC" ])
      expect(again["warning"]).to include("unavailable")
    end

    it "get_quotes answers only-invalid symbols as data, not as a Schwab outage" do
      expect(conforming("get_quotes", symbols: [ "NOPE" ])).to include("quotes" => [], "invalid_symbols" => [ "NOPE" ])
    end

    it "get_quotes serves the cache marked stale when the token is expired, and asks for re-auth with nothing cached" do
      conforming("get_quotes", symbols: [ "XYZ" ])
      travel 3.minutes
      allow(Schwab).to receive(:client).and_raise(Schwab::NoUsableToken, "no usable Schwab token")
      expect(conforming("get_quotes", symbols: [ "XYZ" ])["quotes"].first["stale"]).to be(true)
      expect(Agent::Tools.call("get_price_history", { symbol: "XYZ" }, transport: :mcp).error).to include("re-authentication")
    end

    it "get_price_history maps a range to candles with New York dates" do
      history = conforming("get_price_history", symbol: "xyz", range: "1m")
      expect(history["candles"].first["date"]).to eq("2026-08-31")
      expect(history["previous_close"]).to eq("52.4")
      expect(Agent::Tools.call("get_price_history", { symbol: "XYZ", range: "1d" }, transport: :mcp).error).to include("bad arguments")
    end

    it "draws on a lower Schwab budget ceiling than sync, taken once per request by the client" do
      expect(Schwab).to receive(:client).with(wait: false, budget: 70).and_return(Schwab::FakeClient.instance)
      conforming("get_quotes", symbols: [ "XYZ" ])
    end
  end

  describe "reference tools" do
    it "get_setup_stats and get_risk_rules state their limits" do
      create(:setup, name: "Breakout")
      expect(conforming("get_setup_stats")["setups"].first).to include("name" => "Breakout")
      expect(conforming("get_risk_rules")).to include("available" => false, "rules" => [])
    end
  end
end
