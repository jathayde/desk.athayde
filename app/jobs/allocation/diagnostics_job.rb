module Allocation
  # Saturday 08:00 New York: the cash-drag row, then each held instrument's and each diversifier's correlation with
  # SPY over the correlation rule's window, from Schwab daily history. Each step runs whatever the other did. A
  # symbol that cannot be measured, for any reason including a spent Schwab budget, is named on the run's audit row;
  # what was computed is kept. Reads and writes rows only.
  class DiagnosticsJob < ApplicationJob
    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform(as_of = MarketDay.today)
      account = Account.trading.order(:id).first or return
      step { CashDragDiagnostic.record!(account, as_of: as_of) }
      step { correlate(account, as_of) }
    end

    private
      def step
        yield
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { job: self.class.name })
      end

      def correlate(account, as_of)
        window = RiskRule.active_for("correlation_threshold")&.then { |rule| rule.param(:window_days).to_i } or return
        instruments = (account.positions.includes(:instrument).map(&:instrument) + Instrument.joins(:tags).where(instrument_tags: { tag: "diversifier" }))
                        .uniq.reject { it.delisted? || it.symbol == Correlation::BENCHMARK }
        computed, skipped = 0, {}
        benchmark = closes(Correlation::BENCHMARK) or return audit(as_of, window, 0, instruments.to_h { [ it.symbol, "no fresh SPY history" ] })
        instruments.each_with_index do |instrument, index|
          series = closes(instrument.symbol)
          measure = series ? Correlation.measure(series, benchmark, window: window) : nil
          if measure&.value
            Correlation.find_or_initialize_by(instrument: instrument, as_of: as_of, window_days: window).update!(value: measure.value, last_close_on: measure.last_close_on)
            computed += 1
          else
            skipped[instrument.symbol] = measure&.reason || "no fresh history"
          end
        rescue Schwab::RateLimited
          instruments.drop(index).each { skipped[it.symbol] = "not reached: Schwab rate limit" }
          break
        rescue StandardError => e
          Rails.error.report(e, handled: true, context: { job: self.class.name, symbol: instrument.symbol })
          skipped[instrument.symbol] = "error: #{e.message.truncate(80)}"
        end
        audit(as_of, window, computed, skipped)
      rescue Schwab::RateLimited
        audit(as_of, window, 0, instruments.to_h { [ it.symbol, "not reached: Schwab rate limit" ] })
      end

      # Positive closes by date, or nil when Schwab served only a stale cache or nothing.
      def closes(symbol)
        history = Agent::MarketData.price_history(symbol, range: "1y")
        return nil if history[:stale]
        Array(history[:candles]).filter_map { |candle| [ candle[:date].to_date, BigDecimal(candle[:close].to_s) ] if candle[:close].to_d.positive? }.to_h.presence
      rescue Schwab::RateLimited
        raise
      rescue Schwab::Error
        nil
      end

      def audit(as_of, window, computed, skipped)
        AuditEvent.log("correlation_checked", actor: :system, data: { as_of: as_of.iso8601, window_days: window, computed: computed, skipped: skipped })
      end
  end
end
