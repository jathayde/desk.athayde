module Schwab
  # Same interface as Client, same raw shapes (already scrubbed), served from lib/schwab_fixtures so seeds,
  # Playwright, and specs all run the real mappers. A per-call queue scripts failures and alternate payloads:
  #   Schwab::FakeClient.instance.enqueue(:orders) { raise Schwab::RateLimited.new(retry_after: 30) }
  #   Schwab::FakeClient.instance.enqueue(:orders, sticky: true) { raise Schwab::ServerError }   # every call
  # One process-wide instance, unsynchronized: fine for a single Puma thread in dev and Playwright.
  class FakeClient
    include Singleton

    FIXTURES = Rails.root.join("lib/schwab_fixtures")
    ACCOUNT_HASH = "9313A0737C4E1B2D5F6A7B8C9D0E1F2A3B4C5D6E7F8091A2B3C4D5E6F708192A"
    FAKE_CODE = "fake-authorization-code@"
    NEW_YORK = "America/New_York"

    attr_reader :calls

    def initialize = reset!

    def reset!
      @queues = Hash.new { |h, k| h[k] = [] }
      @sticky = {}
      @calls = []
      @closed_dates = Set.new
      @placed = []
      @next_order_id = 9_000_000_000
      self
    end

    attr_reader :placed

    # Script the next response for a method (or every response with sticky: true). The block receives the call's arguments.
    def enqueue(method_name, sticky: false, &block)
      sticky ? @sticky[method_name] = block : @queues[method_name] << block
    end

    def close_market_on(date) = @closed_dates << date.to_date

    # A plausible daily history for one symbol, served sticky, so the collar has something to measure.
    def script_daily_history(symbol: "XYZ", days: 60, close: 50, range: 1, ending: MarketDay.today)
      zone = ::Time.find_zone!(NEW_YORK)
      candles = (1..days).map do |i|
        date = ending - (days - i)
        c = close + Math.sin(i / 3.0) # a gentle wave, never flat
        { "datetime" => zone.local(date.year, date.month, date.day, 6).to_i * 1000, "open" => c - 0.2, "high" => c + range, "low" => c - range, "close" => c, "volume" => 1_000_000 }
      end
      enqueue(:price_history, sticky: true) { { "candles" => candles, "symbol" => symbol, "empty" => false, "previousClose" => close } }
    end

    # ---- OAuth: the fake authorize page lives in the app (step 4) and redirects straight back
    def authorize_url(state:) = "/schwab/fake_authorize?#{ { state: state }.to_query }"
    def exchange_code(code) = scripted(:exchange_code, code) { code == FAKE_CODE ? token_fixture : raise(ReauthRequired.new("invalid_grant", status: 400)) }
    def refresh(refresh_token) = scripted(:refresh, refresh_token) { token_fixture }

    # ---- Trader API
    def account_numbers = scripted(:account_numbers) { fixture("account_numbers").map { |row| row["hashValue"] } }
    def account(hash, fields: [ :positions ]) = scripted(:account, hash, fields) { fixture("account") }
    def orders(hash, from:, to: ::Time.current, status: nil)
      scripted(:orders, hash, from, to, status) do
        fixture("orders") + @placed.select { |o| (from..to).cover?(::Time.zone.parse(o["enteredTime"])) && (status.nil? || o["status"] == status) }
      end
    end
    def order(hash, order_id) = scripted(:order, hash, order_id) { find_order(fixture("orders") + @placed, order_id.to_s) or raise RequestError.new("order not found", status: 404) }
    def transactions(hash, from:, to: ::Time.current, type:) = scripted(:transactions, hash, from, to, type) { fixture("transactions").select { |a| a["type"] == type } }

    # ---- Market Data API
    def market_hours(date, markets: [ :equity ])
      scripted(:market_hours, date, markets) do
        closed = @closed_dates.include?(date.to_date) || date.to_date.on_weekend?
        closed ? closed_day(date) : open_day(date)
      end
    end
    def quotes(symbols, fields: %w[ quote reference ])
      scripted(:quotes, symbols, fields) do
        known = fixture("quotes").except("errors")
        requested = Array(symbols).map(&:to_s)
        [ known.slice(*requested).merge("errors" => { "invalidSymbols" => requested - known.keys }) ]
      end
    end
    # ---- Orders: a placed order is remembered and served by the next orders call, as Schwab would.
    def place_order(hash, payload) = scripted(:place_order, hash, payload) { place!(payload) }

    # Remember an order as if Schwab had it, with an id of the caller's choosing: specs use it for "the order that
    # was placed while we were not looking".
    def place!(payload, id: (@next_order_id += 1).to_s, status: "WORKING", entered_at: ::Time.current)
      @placed << placed_order(id, payload, status: status, entered_at: entered_at)
      id
    end
    def cancel_order(hash, order_id) = scripted(:cancel_order, hash, order_id) { @placed.find { |o| o["orderId"].to_s == order_id.to_s }&.store("status", "CANCELED"); true }
    def replace_order(hash, order_id, payload) = scripted(:replace_order, hash, order_id, payload) { cancel_order(hash, order_id); place_order(hash, payload) }

    def price_history(symbol, period_type: :month, period: 3, frequency_type: :daily, frequency: 1, from: nil, to: nil) = scripted(:price_history, symbol) { fixture("price_history").merge("symbol" => symbol) }
    def instrument_by_symbol(symbol) = scripted(:instrument_by_symbol, symbol) { fixture("instruments")["instruments"].select { |i| i["symbol"] == symbol } }
    def instrument_by_cusip(cusip) = scripted(:instrument_by_cusip, cusip) { fixture("instruments")["instruments"].select { |i| i["cusip"] == cusip } }

    private
      def scripted(method_name, *args)
        @calls << [ method_name, *args ]
        block = @queues[method_name].shift || @sticky[method_name]
        block ? block.call(*args) : yield
      end

      # The raw shape an order the fake placed comes back in, close enough for the mappers and the matcher.
      # SCHWAB_SHAPE_UNVERIFIED: enteredTime, filledQuantity, remainingQuantity, the AWAITING_PARENT_ORDER child
      # status, and child ids are guessed from schwab-py's examples, not read from a placed order.
      def placed_order(id, payload, status: "WORKING", entered_at: ::Time.current)
        now = entered_at.utc.iso8601(3)
        base = payload.except("childOrderStrategies").merge("orderId" => id.to_i, "status" => status, "enteredTime" => now, "filledQuantity" => 0,
                                                              "remainingQuantity" => payload.dig("orderLegCollection", 0, "quantity"), "quantity" => payload.dig("orderLegCollection", 0, "quantity"),
                                                              "orderLegCollection" => payload["orderLegCollection"].map { |leg| leg.merge("instrument" => leg["instrument"].merge("assetType" => "EQUITY", "cusip" => cusip_for(leg.dig("instrument", "symbol")))) })
        children = Array(payload["childOrderStrategies"]).map { |child| placed_order((@next_order_id += 1), child, status: "AWAITING_PARENT_ORDER") }
        children.any? ? base.merge("childOrderStrategies" => children) : base
      end

      def cusip_for(symbol) = fixture("instruments")["instruments"].find { |i| i["symbol"] == symbol }&.dig("cusip") # the fixture is the broker's reference data

      def fixture(name) = Scrub.json(JSON.parse(FIXTURES.join("#{name}.json").read))

      # The token response is the one body that legitimately carries tokens; the real client never scrubs it either.
      def token_fixture = JSON.parse(FIXTURES.join("token.json").read).except("id_token")

      def find_order(orders, order_id)
        orders.each do |raw|
          return raw if raw["orderId"].to_s == order_id
          found = find_order(Array(raw["childOrderStrategies"]) + Array(raw["replacingOrderCollection"]), order_id)
          return found if found
        end
        nil
      end

      # Session times are built for the requested date in New York, so the offset is right year-round.
      def open_day(date)
        day = date.to_date
        at = ->(hour, minute = 0) { ::Time.find_zone!(NEW_YORK).local(day.year, day.month, day.day, hour, minute).iso8601 }
        { "equity" => { "EQ" => { "date" => day.iso8601, "marketType" => "EQUITY", "product" => "EQ", "productName" => "equity", "isOpen" => true,
          "sessionHours" => { "preMarket" => [ { "start" => at.(7), "end" => at.(9, 30) } ],
                              "regularMarket" => [ { "start" => at.(9, 30), "end" => at.(16) } ],
                              "postMarket" => [ { "start" => at.(16), "end" => at.(20) } ] } } } }
      end

      def closed_day(date)
        { "equity" => { "equity" => { "date" => date.to_date.iso8601, "marketType" => "EQUITY", "product" => "equity", "productName" => "equity", "isOpen" => false } } }
      end
  end
end
