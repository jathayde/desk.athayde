module Research
  # 17:20 New York on weekdays, after the drift check: every open forecast read against its instrument's final daily
  # candles (docs/phase-2.6-plan.md §0.1, §2), one history per instrument, a delisted name read through its successor
  # when the journal knows one. A night without usable candles (stale, empty, Schwab down, a skipped session, a last
  # candle too old to be tonight's) leaves a forecast open and is counted; the fifth in a row voids it as data
  # unavailable, never guessed. A name that ended with no successor settles as
  # a miss once entered, and as never entered otherwise. A rate limit stops the run and the rest wait a night. One
  # audit row per forecast resolved and one for the run. Reads Schwab, writes rows only.
  class ResolveForecastsJob < ApplicationJob
    FAILED_NIGHTS = 5

    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform
      by_instrument = Forecast.open.includes(order_proposal: :instrument).order(:id).group_by { it.order_proposal.instrument }
      results, skipped = Hash.new(0), {}
      closed_days = MarketDay.where(trading: false, date: 1.year.ago.to_date..).pluck(:date)
      by_instrument.each_with_index do |(instrument, forecasts), index|
        candles = candles_for(instrument)
        forecasts.each do |forecast|
          results[resolve(forecast, instrument, candles, closed_days)] += 1
        rescue StandardError => e # one forecast's failure never holds up the others
          Rails.error.report(e, handled: true, context: { job: self.class.name, forecast: forecast.id })
          results["error"] += 1
        end
      rescue Schwab::RateLimited
        by_instrument.keys.drop(index).each { skipped[it.symbol] = "not reached: Schwab rate limit" }
        break
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { job: self.class.name, symbol: instrument.symbol })
        skipped[instrument.symbol] = "error: #{e.message.truncate(80)}"
      end
      AuditEvent.log("forecasts_checked", actor: :system, data: { open: by_instrument.values.sum(&:size), results: results, skipped: skipped })
    end

    private
      # The outcome written, or "open" / "no_data" for a forecast the night left open. A name that has ended is
      # settled on whatever history is left, none included.
      def resolve(forecast, instrument, candles, closed_days)
        ended = ended?(instrument)
        return forecast.record_failed_night!(void_after: FAILED_NIGHTS) if candles.nil? && !ended
        verdict = Forecast::Resolution.call(forecast, candles || [], ended: ended, closed_days: closed_days)
        return forecast.record_failed_night!(void_after: FAILED_NIGHTS) if Forecast::Resolution.gap?(verdict)
        # A history that stopped while the name was in the trade is a name that stopped trading, delisted or not:
        # a miss once entered, never a void, so the losers that vanish stay in the score.
        return forecast.record_failed_night!(void_after: FAILED_NIGHTS, ended: verdict) if verdict.outcome.nil? && behind?(candles)
        forecast.resolve!(verdict)
        forecast.outcome || "open"
      end

      # Tonight's history ends before the last session it should hold: the name stopped trading, or Schwab is behind.
      def behind?(candles) = candles.present? && candles.last[:date] < StopCollar::Candles.oldest_acceptable_date

      def ended?(instrument) = instrument.delisted? && successor(instrument).nil?
      def successor(instrument) = Instrument.find_by(predecessor_instrument: instrument)

      # Final candles with dates and prices as the rule reads them, or nil when tonight's history cannot be used.
      def candles_for(instrument)
        source = (instrument.delisted? && successor(instrument)) || instrument
        history = Agent::MarketData.price_history(source.symbol, range: "1y")
        return nil if history[:stale] || history[:empty] || Array(history[:candles]).empty?
        candles = history[:candles].map { |c| c = c.transform_keys(&:to_sym); { date: c[:date].to_date, high: c[:high].to_d, low: c[:low].to_d, close: c[:close].to_d } }
        StopCollar::Candles.final(candles, fetched_at: history[:fetched_at] || Time.current).sort_by { it[:date] }
      rescue Schwab::RateLimited
        raise
      rescue Schwab::Error
        nil
      end
  end
end
