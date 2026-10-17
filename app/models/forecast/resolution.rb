# The scoring rule as a pure function of a forecast and its instrument's final daily candles
# (docs/phase-2.6-plan.md §0.1). The entry is the first of five sessions from starts_on whose low reaches the
# limit; on that day only the stop is tested, since a daily bar cannot order the fill against the levels (a stop
# there is ambiguous only if the day also reached the target). Then
# horizon_days sessions: a day touching both levels is the stop, marked ambiguous; the last of them untouched is
# a miss, marked expired. A close on the reference day more than 2% from the one frozen, or a one-day move on the
# path read that lands on a split ratio (2:1, 3:1, 3:2, ... and their reverses), is a split or a restatement and
# voids rather than mis-resolves; any other move, however large, is scored. A path that skips a session the
# calendar does not call closed, or lacks the reference candle, is not read across: it stays open with the gap
# named, and the caller counts the night as failed. Candles running out leave it open, unless the caller says the
# name has ended: then a miss once entered (on any night), and never entered otherwise.
class Forecast::Resolution
  VERSION = 2 # 2: an entry-day stop is ambiguous only when that day also reached the target
  ENTRY_WINDOW = 5
  REFERENCE_TOLERANCE = BigDecimal("0.02")
  SPLIT_RATIOS = [ 2, 3, 4, 5, 10, Rational(3, 2) ].flat_map { [ it.to_r, 1 / it.to_r ] }.freeze
  SPLIT_TOLERANCE = BigDecimal("0.03") # a day's own move on top of the ratio

  Verdict = Data.define(:outcome, :void_reason, :checked_through, :detail)

  def self.call(forecast, candles, ended: false, closed_days: []) = new(forecast, candles, ended: ended, closed_days: closed_days).call

  # candles: final daily candles, any order, symbol keys, :date a Date and the prices BigDecimal. closed_days: the
  # weekdays the calendar calls closed, so a holiday is not taken for a gap.
  def initialize(forecast, candles, ended: false, closed_days: [])
    @forecast, @candles, @ended, @closed_days = forecast, candles.sort_by { |c| c[:date] }, ended, closed_days.to_set
  end

  def self.gap?(verdict) = verdict.outcome.nil? && verdict.detail.key?("gap")

  def call
    verdict = read
    @ended && verdict.outcome.nil? ? ended(verdict) : verdict
  end

  private
    attr_reader :forecast, :candles

    def read
      return pending if candles.empty?
      return pending(gap: "no candle for the reference day #{forecast.reference_on.iso8601}") unless reference
      return void("split", reference_close: reference[:close].to_s) if restated?
      entry_at = window.first(ENTRY_WINDOW).index { |c| c[:low] <= forecast.entry_price }
      if entry_at.nil?
        return checked(window.last) || pending if window.size < ENTRY_WINDOW
        return checked(window[ENTRY_WINDOW - 1]) || void("never_entered")
      end
      entered_on = window[entry_at][:date].iso8601
      candle, outcome, flags = decide(entry_at)
      checked(candle || window.last) || (candle ? settle(candle, outcome, flags, entered_on: entered_on) : pending(entered_on: entered_on))
    end

    def window = @window ||= candles.select { |c| c[:date] >= forecast.starts_on }
    def reference = defined?(@reference) ? @reference : (@reference = candles.find { |c| c[:date] == forecast.reference_on })

    # The deciding candle, its outcome, and its flags; nil while the horizon is still running.
    def decide(entry_at)
      entry = window[entry_at]
      return [ entry, "miss", { ambiguous: entry[:high] >= forecast.target_price, stopped_on_entry_day: true }.select { _2 } ] if entry[:low] <= forecast.stop_price
      horizon = window[entry_at + 1, forecast.horizon_days]
      horizon.each do |c|
        stopped, reached = c[:low] <= forecast.stop_price, c[:high] >= forecast.target_price
        return [ c, "miss", { ambiguous: true } ] if stopped && reached
        return [ c, "miss", {} ] if stopped
        return [ c, "hit", {} ] if reached
      end
      horizon.size == forecast.horizon_days ? [ horizon.last, "miss", { expired: true } ] : nil
    end

    def ended(verdict)
      entered = verdict.detail["entered_on"] || forecast.detail["entered_on"]
      verdict.with(outcome: entered ? "miss" : "void", void_reason: entered ? nil : "never_entered", detail: verdict.detail.merge("ended_early" => true))
    end

    def restated? = reference && (reference[:close] / forecast.reference_close - 1).abs > REFERENCE_TOLERANCE

    # The path read, from the reference close through the given candle, checked for what it cannot be read across:
    # a skipped session (open, the gap named) or a split (void). Nil when it reads clean.
    def checked(through)
      return nil unless through
      path = candles.select { |c| c[:date] >= forecast.reference_on && c[:date] <= through[:date] }
      path.each_cons(2) do |prev, c|
        return pending(gap: "no candle between #{prev[:date].iso8601} and #{c[:date].iso8601}") if skipped?(prev[:date], c[:date])
        return void("split", moved_on: c[:date].iso8601) if split_like?(c[:close] / prev[:close])
      end
      nil
    end

    def skipped?(from, to) = ((from + 1)...to).any? { |day| !day.on_weekend? && !@closed_days.include?(day) }
    def split_like?(ratio) = SPLIT_RATIOS.any? { |split| (ratio / split - 1).abs <= SPLIT_TOLERANCE }

    def settle(candle, outcome, flags, entered_on:)
      verdict(outcome, nil, candle[:date], entered_on: entered_on, decided_on: candle[:date].iso8601, **flags)
    end

    def void(reason, **detail) = verdict("void", reason, window.last&.dig(:date) || forecast.checked_through, **detail)
    def pending(**detail) = verdict(nil, nil, window.last&.dig(:date) || forecast.checked_through, **detail)
    def verdict(outcome, reason, through, **detail) = Verdict.new(outcome: outcome, void_reason: reason, checked_through: through, detail: stamp(detail))
    def stamp(detail) = { "resolver_version" => VERSION }.merge(detail.stringify_keys)
end
