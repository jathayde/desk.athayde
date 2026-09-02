require "net/http"

module Schwab
  # The only code that speaks HTTP to Schwab. Returns scrubbed raw hashes; the structs in this
  # namespace turn them into typed values. Every field name here is SCHWAB_SHAPE_UNVERIFIED
  # until docs/verify-on-approval.md is worked through.
  class Client
    TRADER = "https://api.schwabapi.com/trader/v1"
    MARKET = "https://api.schwabapi.com/marketdata/v1"
    OAUTH = "https://api.schwabapi.com/v1/oauth"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    BACKOFF = [ 1, 4, 16 ].freeze
    MAX_ATTEMPTS = BACKOFF.size + 1
    RETRY_AFTER_CAP = 60
    TRANSPORT_FAILURES = [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Net::HTTPBadResponse, EOFError, IOError,
                           Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
                           SocketError, OpenSSL::SSL::SSLError ].freeze
    # token responds to #access_token and, if it can renew itself, #refresh!
    # wait: false raises on the first retriable failure instead of sleeping; web callers use it.
    # budget: the per-minute ceiling this client draws against on the shared counter; callers that must not
    # starve sync pass a lower one. One take per request, here and nowhere else.
    def initialize(token: nil, app_key: Schwab.app_key, app_secret: Schwab.app_secret, callback_url: Schwab.callback_url,
                   sleeper: method(:sleep), wait: true, budget: Schwab::RATE_BUDGET_PER_MINUTE)
      # A missing app key would send an empty Basic auth header and read Schwab's 401 as a revoked token.
      raise NotConfigured, "Schwab app key and secret are not in credentials" if app_key.blank? || app_secret.blank?
      @token, @app_key, @app_secret, @callback_url, @sleeper, @wait, @budget = token, app_key, app_secret, callback_url, sleeper, wait, budget
    end

    # ---- OAuth -----------------------------------------------------------------------------

    def authorize_url(state:)
      "#{OAUTH}/authorize?" + URI.encode_www_form(response_type: "code", client_id: @app_key, redirect_uri: @callback_url, state: state)
    end

    # params[:code] is already URL-decoded once by Rails; it ends in "@". Do not decode again.
    def exchange_code(code)
      token_request({ grant_type: "authorization_code", code: code, redirect_uri: @callback_url }, idempotent: false)
    end

    def refresh(refresh_token)
      token_request({ grant_type: "refresh_token", refresh_token: refresh_token }, idempotent: true)
    end

    # ---- Trader API ------------------------------------------------------------------------

    # Hash values only; the plaintext numbers never leave this method.
    def account_numbers
      get(TRADER, "/accounts/accountNumbers").map { |row| row["hashValue"] }
    end

    def account(hash, fields: [ :positions ])
      get(TRADER, "/accounts/#{hash}", fields: Array(fields).join(","))
    end

    def orders(hash, from:, to: ::Time.current, status: nil)
      params = { fromEnteredTime: Timestamp.iso_ms(from), toEnteredTime: Timestamp.iso_ms(to), maxResults: 3000 }
      params[:status] = status if status
      get(TRADER, "/accounts/#{hash}/orders", **params)
    end

    def order(hash, order_id)
      get(TRADER, "/accounts/#{hash}/orders/#{order_id}")
    end

    # One type per request; the activities feed iterates Schwab::Activity::CASH_ACCOUNT_TYPES so a failure mid-way keeps what came before.
    def transactions(hash, from:, to: ::Time.current, type:)
      get(TRADER, "/accounts/#{hash}/transactions", startDate: Timestamp.iso_ms(from), endDate: Timestamp.iso_ms(to), types: type)
    end

    # ---- Market Data API -------------------------------------------------------------------

    def market_hours(date, markets: [ :equity ])
      get(MARKET, "/markets", markets: Array(markets).join(","), date: Timestamp.date(date))
    end

    def quotes(symbols, fields: %w[ quote reference ])
      Array(symbols).each_slice(Schwab::QUOTE_BATCH).map do |batch|
        get(MARKET, "/quotes", symbols: batch.join(","), fields: fields.join(","), indicative: false)
      end
    end

    def price_history(symbol, period_type: :month, period: 3, frequency_type: :daily, frequency: 1, from: nil, to: nil)
      params = { symbol: symbol, periodType: period_type, period: period, frequencyType: frequency_type, frequency: frequency,
                 needExtendedHoursData: false, needPreviousClose: true }
      params[:startDate] = Timestamp.epoch_ms(from) if from
      params[:endDate] = Timestamp.epoch_ms(to) if to
      get(MARKET, "/pricehistory", **params)
    end

    def instrument_by_symbol(symbol)
      get(MARKET, "/instruments", symbol: symbol, projection: "symbol-search").fetch("instruments", [])
    end

    def instrument_by_cusip(cusip)
      get(MARKET, "/instruments/#{cusip}").fetch("instruments", [])
    end

    private
      def token_request(form, idempotent:)
        request = Net::HTTP::Post.new(URI("#{OAUTH}/token"))
        request.basic_auth(@app_key, @app_secret)
        request["Accept"] = "application/json"
        request.set_form_data(form)
        response, attempts = perform(request, template: "/v1/oauth/token", idempotent: idempotent)
        error = Error.for_response(response, attempts: attempts, idempotent: idempotent)
        case response.code.to_i
        when 200..299 then parse(response, attempts: attempts, idempotent: idempotent).except("id_token")
        when 400, 401, 403 then raise ReauthRequired.new(error.message, status: error.status, body: error.body, attempts: attempts)
        else raise error
        end
      end

      def get(base, path, **params)
        uri = URI("#{base}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?
        response, attempts = authorized(uri)
        raise Error.for_response(response, attempts: attempts, idempotent: true) unless response.is_a?(Net::HTTPSuccess)
        Scrub.json(parse(response, attempts: attempts, idempotent: true))
      end

      # A non-JSON success body is a gateway page, not data.
      def parse(response, attempts:, idempotent:)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise (idempotent ? ServerError : UnknownOutcome).new("Schwab returned a non-JSON body", status: response.code.to_i,
                                                              body: Scrub.body(response.body), attempts: attempts)
      end

      # One refresh-and-retry on 401, outside the backoff budget. The token model decides whether a
      # refresh is still needed, so two processes seeing the same 401 cannot double-refresh.
      def authorized(uri, refreshed: false)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@token.access_token}"
        request["Accept"] = "application/json"
        response, attempts = perform(request, template: Scrub.path(uri.path), idempotent: true)
        if response.code.to_i == 401 && !refreshed && @token.respond_to?(:refresh!)
          @token.refresh!(wait: @wait)
          return authorized(uri, refreshed: true)
        end
        [ response, attempts ]
      end

      # Returns [response, attempts]. Retries live here and nowhere else.
      def perform(request, template:, idempotent:)
        final = idempotent && @wait ? MAX_ATTEMPTS : 1
        1.upto(final) do |attempt|
          begin
            response = dispatch(request, template)
          rescue *TRANSPORT_FAILURES => e
            raise transport_failure(e, attempt, idempotent) if attempt == final
            @sleeper.call(jittered(BACKOFF[attempt - 1]))
            next
          end
          return [ response, attempt ] unless retriable?(response) && attempt < final
          @sleeper.call(delay_for(response, attempt))
        end
      end

      def dispatch(request, template)
        RateBudget.take!(budget: @budget)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        http(request.uri).request(request).tap { |response| log(request, template, response.code, started) }
      rescue *TRANSPORT_FAILURES
        log(request, template, "transport", started)
        raise
      end

      def transport_failure(error, attempts, idempotent)
        (idempotent ? TransportError : UnknownOutcome).new("#{error.class}: #{error.message}", attempts: attempts)
      end

      def retriable?(response) = response.code.to_i == 429 || response.code.to_i >= 500

      def delay_for(response, attempt)
        retry_after = Error.retry_after_in(response)
        retry_after ? [ retry_after, RETRY_AFTER_CAP ].min : jittered(BACKOFF[attempt - 1])
      end

      def jittered(seconds) = seconds + rand * seconds * 0.25

      def http(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |h|
          h.use_ssl = true
          h.open_timeout = OPEN_TIMEOUT
          h.read_timeout = READ_TIMEOUT
        end
      end

      def log(request, template, status, started)
        ms = started ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round : 0
        Rails.logger.info("schwab #{request.method} #{template} #{status} #{ms}ms")
      end
  end
end
