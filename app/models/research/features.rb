# What the desk saw when an entry was proposed (docs/phase-2.6-plan.md §0.4), frozen on the proposal with its
# formula version, to be joined to outcomes later; nothing reads it to decide. Every feature comes from final daily
# candles only (never today's partial bar), the instrument's and SPY's through the same tool cache the collar
# reads, and a history that is stale or ends more than two trading days ago is not read at all. A feature the
# history cannot support is missing with the reason, never estimated from fewer bars than it needs, and one
# feature's failure is that feature's alone. Never refuses a proposal.
#
# Units (version 1): every value is a fraction, 0.05 meaning 5%. close_vs_smaN is the last close over its plain
# N-session average (the last close included) less one; volume_vs_avg20 the last session's volume over the
# average of the 20 before it, less one; atr14_ratio the plain mean of 14 true ranges over the last close;
# return63_less_spy the 63-session return less the benchmark's over the same sessions; open_risk_ratio the
# protected positions' open risk over equity, with what it leaves out in context. Change any of these and bump
# VERSION; spec/models/research/features_spec.rb pins the values.
class Research::Features
  VERSION = 1
  BENCHMARK = Correlation::BENCHMARK
  ATR_DAYS = 14
  RELATIVE_DAYS = 63
  VOLUME_DAYS = 20
  # Each feature's label and how a page shows it.
  FEATURES = {
    "atr14_ratio" => [ "ATR(14) of the close", :percent ],
    "close_vs_sma20" => [ "Close against its 20-day average", :signed_percent ],
    "close_vs_sma50" => [ "Close against its 50-day average", :signed_percent ],
    "close_vs_sma200" => [ "Close against its 200-day average", :signed_percent ],
    "return63_less_spy" => [ "63-session return less SPY's", :signed_percent ],
    "volume_vs_avg20" => [ "Volume against its 20-day average", :signed_percent ],
    "open_risk_ratio" => [ "Open risk of equity", :percent ]
  }.freeze

  Missing = Data.define(:reason)

  def self.snapshot(proposal, now: Time.current) = new(proposal, now: now).snapshot

  def initialize(proposal, now:)
    @proposal, @now = proposal, now
  end

  def snapshot
    missing, values = measures.partition { |_, value| value.is_a?(Missing) }.map(&:to_h)
    { "version" => VERSION, "computed_at" => @now.iso8601, "benchmark" => BENCHMARK, "reference_on" => @proposal.reference_on&.iso8601,
      "bars_through" => candles&.all&.last&.dig(:date)&.iso8601, "spy_bars_through" => spy&.all&.last&.dig(:date)&.iso8601,
      "values" => values.transform_values { it.round(6) }, "missing" => missing.transform_values(&:reason), "context" => @context.to_h }
  rescue StandardError => e # a snapshot is evidence, never a gate
    Rails.error.report(e, handled: true, context: { features: @proposal.instrument&.symbol, account: @proposal.account_id })
    { "version" => VERSION, "computed_at" => @now.iso8601, "values" => {}, "missing" => { "all" => "error: #{e.message.truncate(120)}" } }
  end

  private
    def measures
      { "atr14_ratio" => -> { market(ATR_DAYS + 1) { ratio(candles.atr(ATR_DAYS), close) } },
        "close_vs_sma20" => -> { average(20) }, "close_vs_sma50" => -> { average(50) }, "close_vs_sma200" => -> { average(200) },
        "return63_less_spy" => -> { relative_return }, "volume_vs_avg20" => -> { market(VOLUME_DAYS + 1) { volume_ratio } }, "open_risk_ratio" => -> { open_risk } }
        .transform_values do |measure|
          measure.call
        rescue StandardError => e # one feature's failure is its own
          Rails.error.report(e, handled: true, context: { features: @proposal.instrument&.symbol }) unless e.is_a?(Schwab::Error)
          Missing.new("error: #{e.message.truncate(80)}")
        end
    end

    def average(days) = market(days) { ratio(close, candles.last(days).sum { it[:close] } / days) - 1 }

    def volume_ratio
      prior = candles.last(VOLUME_DAYS + 1).first(VOLUME_DAYS).sum { it[:volume].to_f }
      prior.positive? ? candles.all.last[:volume].to_f / (prior / VOLUME_DAYS) - 1 : Missing.new("no volume in the prior #{VOLUME_DAYS} sessions")
    end

    # The 63-session return less SPY's, over the same sessions: missing unless both series end on the same day.
    def relative_return
      return Missing.new(candles_why) unless candles
      return Missing.new("SPY: #{spy_why}") unless spy
      return Missing.new("the instrument's last bar (#{candles.all.last[:date]}) is not SPY's (#{spy.all.last[:date]})") unless candles.all.last[:date] == spy.all.last[:date]
      spy_by_date = spy.all.to_h { [ it[:date], it[:close] ] }
      shared = candles.all.select { spy_by_date.key?(it[:date]) }
      return Missing.new("#{shared.size} shared sessions; #{RELATIVE_DAYS + 1} needed") if shared.size < RELATIVE_DAYS + 1
      from, to = shared.last(RELATIVE_DAYS + 1).values_at(0, -1)
      ratio(to[:close], from[:close]) - ratio(spy_by_date[to[:date]], spy_by_date[from[:date]])
    end

    # Protected positions only, as the desk counts it: what it leaves out goes in context, so two ratios taken under
    # different protection are never read as the same thing.
    def open_risk
      desk = Desk.new(account: @proposal.account)
      return Missing.new("the desk is #{desk.state.to_s.humanize(capitalize: false)}") unless desk.ready?
      (@context ||= {})["open_risk_excluded"] = desk.excluded_by_reason.transform_keys(&:to_s) # as jsonb holds it, so the row reads unchanged after save
      desk.open_risk_ratio&.to_f || Missing.new("no equity to divide by")
    end

    # A market feature from at least count final candles, or why there are not enough.
    def market(count)
      return Missing.new(candles_why) unless candles
      candles.all.size >= count ? yield : Missing.new("#{candles.all.size} final candles; #{count} needed")
    end

    def close = candles.all.last[:close]
    def ratio(a, b) = b.zero? ? raise(ZeroDivisionError, "a zero divisor") : (a / b).to_f # rounded once, in the snapshot

    def candles = (@candles ||= final_candles(@proposal.instrument.symbol)).first
    def candles_why = (@candles ||= final_candles(@proposal.instrument.symbol)).last
    def spy = (@spy ||= final_candles(BENCHMARK)).first
    def spy_why = (@spy ||= final_candles(BENCHMARK)).last

    # The final candles as StopCollar::Candles, with nil and the reason when they cannot be read.
    def final_candles(symbol)
      read = StopCollar::Candles.read(symbol)
      final = StopCollar::Candles.final(read.all, fetched_at: [ read.fetched_at, @now ].compact.min)
      return [ nil, "no final candles" ] if final.empty?
      return [ nil, "the last final candle is #{final.last[:date]}, more than two trading days old" ] if final.last[:date].to_date < StopCollar::Candles.oldest_acceptable_date
      [ StopCollar::Candles.new(final), nil ]
    rescue StopCollar::Candles::Refused => e
      [ nil, e.message ]
    rescue Schwab::Error => e # a rate limit included: the proposal goes ahead without the features
      [ nil, "history unavailable: #{e.message.truncate(80)}" ]
    end
end
