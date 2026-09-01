require "rails_helper"

RSpec.describe Schwab::Client do
  let(:hash) { Schwab::FakeClient::ACCOUNT_HASH }
  let(:token) { instance_double("SchwabToken", access_token: "tok-1") }
  let(:sleeps) { [] }
  let(:client) { described_class.new(token: token, app_key: "key", app_secret: "secret", callback_url: "https://desk.example.com/schwab/callback", sleeper: ->(s) { sleeps << s }) }
  let(:trader) { "https://api.schwabapi.com/trader/v1" }
  let(:market) { "https://api.schwabapi.com/marketdata/v1" }
  let(:token_url) { "https://api.schwabapi.com/v1/oauth/token" }

  it "refuses to build without app credentials rather than sending empty Basic auth" do
    expect { described_class.new(token: token, app_key: nil, app_secret: "s", callback_url: "https://x/cb") }.to raise_error(Schwab::NotConfigured)
  end

  describe "OAuth" do
    it "builds the authorize URL" do
      expect(client.authorize_url(state: "s1")).to eq("https://api.schwabapi.com/v1/oauth/authorize?response_type=code&client_id=key&redirect_uri=https%3A%2F%2Fdesk.example.com%2Fschwab%2Fcallback&state=s1")
    end

    it "exchanges a code with Basic auth and a form body, dropping the id_token" do
      stub = stub_request(:post, token_url)
        .with(basic_auth: [ "key", "secret" ], body: { grant_type: "authorization_code", code: "abc@", redirect_uri: "https://desk.example.com/schwab/callback" })
        .to_return(status: 200, body: schwab_fixture("token").to_json)
      result = client.exchange_code("abc@")
      expect(stub).to have_been_requested
      expect(result).to include("access_token" => "fake-access-token", "refresh_token" => "fake-refresh-token", "expires_in" => 1800)
      expect(result).not_to have_key("id_token")
    end

    it "treats 400, 401, and 403 from the token endpoint as re-auth required, without retrying" do
      stub_request(:post, token_url).to_return(status: 400, body: '{"error":"invalid_grant","error_description":"refresh token expired"}')
      expect { client.refresh("old") }.to raise_error(Schwab::ReauthRequired, /refresh token expired/)
      expect(sleeps).to be_empty
    end

    it "treats a rate-limited refresh as rate limiting, not re-auth" do
      stub_request(:post, token_url).to_return(status: 429, headers: { "Retry-After" => "7" })
      expect { client.refresh("old") }.to raise_error(Schwab::RateLimited) { |e| expect(e.retry_after).to eq(7) }
      expect(sleeps).to eq([ 7, 7, 7 ])
    end

    it "treats a 5xx on the code exchange as an unknown outcome and does not retry it" do
      stub_request(:post, token_url).to_return(status: 502)
      expect { client.exchange_code("abc@") }.to raise_error(Schwab::UnknownOutcome)
      expect(sleeps).to be_empty
    end
  end

  describe "requests" do
    it "sends the bearer token, formats windows in UTC milliseconds, and scrubs the body" do
      stub = stub_request(:get, "#{trader}/accounts/#{hash}/orders")
        .with(headers: { "Authorization" => "Bearer tok-1", "Accept" => "application/json" },
              query: { fromEnteredTime: "2026-08-01T00:00:00.000Z", toEnteredTime: "2026-09-01T12:00:00.000Z", maxResults: "3000" })
        .to_return(status: 200, body: schwab_fixture("orders").to_json)
      orders = client.orders(hash, from: Time.utc(2026, 8, 1), to: Time.utc(2026, 9, 1, 12))
      expect(stub).to have_been_requested
      expect(orders.first["accountNumber"]).to be_nil
      expect(orders.first["orderId"]).to eq(1004055538123)
    end

    it "returns hash values only from accountNumbers" do
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_return(status: 200, body: schwab_fixture("account_numbers").to_json)
      expect(client.account_numbers).to eq([ hash ])
    end

    it "fetches one order by id, positions with the fields param, and one transaction type per call" do
      order = stub_request(:get, "#{trader}/accounts/#{hash}/orders/123").to_return(status: 200, body: "{\"orderId\":123}")
      account = stub_request(:get, "#{trader}/accounts/#{hash}").with(query: { fields: "positions" }).to_return(status: 200, body: "{}")
      tx = stub_request(:get, "#{trader}/accounts/#{hash}/transactions").with(query: hash_including(types: "TRADE", startDate: "2026-08-01T00:00:00.000Z")).to_return(status: 200, body: "[]")
      client.order(hash, 123)
      client.account(hash)
      client.transactions(hash, from: Time.utc(2026, 8, 1), type: "TRADE")
      expect([ order, account, tx ]).to all(have_been_requested)
    end

    it "hits the market data endpoints with the contract's parameters" do
      hours = stub_request(:get, "#{market}/markets").with(query: { markets: "equity", date: "2026-09-08" }).to_return(status: 200, body: "{}")
      history = stub_request(:get, "#{market}/pricehistory").with(query: hash_including(symbol: "XYZ", periodType: "month", period: "3", frequencyType: "daily", needPreviousClose: "true")).to_return(status: 200, body: "{}")
      by_symbol = stub_request(:get, "#{market}/instruments").with(query: { symbol: "XYZ", projection: "symbol-search" }).to_return(status: 200, body: '{"instruments":[]}')
      by_cusip = stub_request(:get, "#{market}/instruments/037833100").to_return(status: 200, body: '{"instruments":[]}')
      client.market_hours(Date.new(2026, 9, 8))
      client.price_history("XYZ")
      client.instrument_by_symbol("XYZ")
      client.instrument_by_cusip("037833100")
      expect([ hours, history, by_symbol, by_cusip ]).to all(have_been_requested)
    end

    it "chunks quote symbols and returns every page" do
      symbols = (1..150).map { |i| "S#{i}" }
      first = stub_request(:get, "#{market}/quotes").with(query: hash_including(symbols: symbols.first(100).join(","))).to_return(status: 200, body: '{"errors":{"invalidSymbols":["S1"]}}')
      second = stub_request(:get, "#{market}/quotes").with(query: hash_including(symbols: symbols.last(50).join(","))).to_return(status: 200, body: '{"errors":{"invalidSymbols":["S150"]}}')
      pages = client.quotes(symbols)
      expect([ first, second ]).to all(have_been_requested)
      expect(Schwab::Quote.batch(pages).invalid_symbols).to eq(%w[ S1 S150 ])
    end

    it "turns a non-JSON 200 into a ServerError" do
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_return(status: 200, body: "<html>gateway</html>")
      expect { client.account_numbers }.to raise_error(Schwab::ServerError, /non-JSON/)
    end
  end

  describe "resilience" do
    it "retries 5xx and 429 with backoff, honoring Retry-After up to the cap" do
      stub_request(:get, "#{trader}/accounts/accountNumbers")
        .to_return({ status: 503 }, { status: 429, headers: { "Retry-After" => "500" } }, { status: 200, body: "[]" })
      expect(client.account_numbers).to eq([])
      expect(sleeps.size).to eq(2)
      expect(sleeps.first).to be_between(1, 1.25)
      expect(sleeps.last).to eq(60)
    end

    it "gives up after the budget with the right class and count" do
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_return(status: 502)
      expect { client.account_numbers }.to raise_error(Schwab::ServerError) { |e| expect(e.attempts).to eq(4) }
    end

    it "carries Retry-After on a final 429" do
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_return(status: 429, headers: { "Retry-After" => "30" })
      expect { client.account_numbers }.to raise_error(Schwab::RateLimited) { |e| expect(e.retry_after).to eq(30) }
    end

    it "raises immediately in no-wait mode" do
      client = described_class.new(token: token, app_key: "k", app_secret: "s", callback_url: "https://x/cb", sleeper: ->(s) { sleeps << s }, wait: false)
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_return(status: 503)
      expect { client.account_numbers }.to raise_error(Schwab::ServerError) { |e| expect(e.attempts).to eq(1) }
      expect(sleeps).to be_empty
    end

    it "never retries a 4xx" do
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_return(status: 400, body: '{"errors":[{"id":"r1","detail":"bad window"}]}')
      expect { client.account_numbers }.to raise_error(Schwab::RequestError, /bad window/) { |e| expect(e.request_id).to eq("r1") }
      expect(sleeps).to be_empty
    end

    it "refreshes the token once on 401 and retries" do
      token = double("SchwabToken")
      allow(token).to receive(:access_token).and_return("tok-old", "tok-new")
      allow(token).to receive(:refresh!)
      client = described_class.new(token: token, app_key: "k", app_secret: "s", callback_url: "https://x/cb", sleeper: ->(_) { })
      stub_request(:get, "#{trader}/accounts/accountNumbers").with(headers: { "Authorization" => "Bearer tok-old" }).to_return(status: 401)
      stub_request(:get, "#{trader}/accounts/accountNumbers").with(headers: { "Authorization" => "Bearer tok-new" }).to_return(status: 200, body: "[]")
      expect(client.account_numbers).to eq([])
      expect(token).to have_received(:refresh!).once
    end

    it "raises AuthError when the retry after refresh is still unauthorized" do
      token = double("SchwabToken", access_token: "tok", refresh!: nil)
      client = described_class.new(token: token, app_key: "k", app_secret: "s", callback_url: "https://x/cb", sleeper: ->(_) { })
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_return(status: 401)
      expect { client.account_numbers }.to raise_error(Schwab::AuthError)
    end

    it "wraps transport failures on reads as TransportError after jittered retries" do
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_timeout
      expect { client.account_numbers }.to raise_error(Schwab::TransportError) { |e| expect(e.attempts).to eq(4) }
      expect(sleeps.size).to eq(3)
      expect(sleeps[0]).to be_between(1, 1.25)
      expect(sleeps[2]).to be_between(16, 20)
    end

    it "wraps transport failures on the code exchange as UnknownOutcome without retrying" do
      stub_request(:post, token_url).to_timeout
      expect { client.exchange_code("abc@") }.to raise_error(Schwab::UnknownOutcome)
      expect(sleeps).to be_empty
    end

    it "surfaces the local rate budget through the client" do
      stub_request(:get, "#{trader}/accounts/accountNumbers").to_return(status: 200, body: "[]")
      Schwab::RATE_BUDGET_PER_MINUTE.times { Schwab::RateBudget.take! }
      expect { client.account_numbers }.to raise_error(Schwab::RateLimited, /Local Schwab rate budget/)
    end

    it "logs the path template, never the account hash" do
      stub_request(:get, "#{trader}/accounts/#{hash}").with(query: hash_including({})).to_return(status: 200, body: "{}")
      allow(Rails.logger).to receive(:info).and_call_original
      client.account(hash)
      expect(Rails.logger).to have_received(:info).with(%r{\Aschwab GET /trader/v1/accounts/\{hash\} 200 \d+ms\z})
    end
  end
end
