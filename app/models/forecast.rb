# A claim about the price path once an entry is touched (docs/phase-2.6-plan.md §0.1, §0.2): within horizon_days
# sessions of the market reaching the entry, the high reaches the target before the low reaches the stop, with a
# probability. One per author per entry proposal, its levels always the proposal's own, scored on Schwab's daily
# candles whatever happened to the order. The database freezes the claim once written and the outcome once
# resolved; the nightly resolver is the only writer of the outcome.
class Forecast < ApplicationRecord
  CLAIM = %i[ order_proposal_id author user_id probability horizon_days entry_price target_price stop_price reference_close reference_on reference_volatility starts_on made_at saw_agent_forecast ].freeze
  HORIZON = 1..60
  REGULAR_OPEN = [ 9, 30 ] # the starts_on rule needs only the open, which no early close moves
  FLAGS = %w[ ambiguous stopped_on_entry_day expired ended_early ].freeze

  belongs_to :order_proposal
  belongs_to :user, optional: true

  enum :author, { agent: "agent", human: "human" }, prefix: true
  enum :outcome, { hit: "hit", miss: "miss", void: "void" }, prefix: true

  attr_readonly(*CLAIM)

  scope :open, -> { where(outcome: nil) }

  # Levels the forecast cannot be measured on: the proposal is not refused for them, only left without a forecast,
  # so the forecast is never what decides whether an entry is proposed (docs/phase-2.6-plan.md §8).
  class Unmeasurable < ArgumentError; end

  # Inside the proposal's own transaction when it comes with the proposal, so a refused creation writes none.
  # The probability and horizon are the author's; everything else is the proposal's. Whether the operator had seen
  # the agent's first is read from the record of the reveal, never from the form.
  def self.record!(proposal, author:, probability:, horizon_days:, user: nil)
    probability = BigDecimal(probability.to_s, exception: false)&.round(4) # validated as stored
    horizon = Integer(horizon_days.to_s, exception: false)
    raise ArgumentError, "probability must be between 0 and 1, exclusive, to four places" unless probability && probability > 0 && probability < 1
    raise ArgumentError, "horizon must be #{HORIZON.first} to #{HORIZON.last} sessions" unless horizon && HORIZON.cover?(horizon)
    measurable!(proposal)
    made_at = Time.current
    saw = author.to_s == "human" && proposal.agent_forecast_revealed_to?(user)
    create!(order_proposal: proposal, author: author, user: user, probability: probability, horizon_days: horizon, made_at: made_at, starts_on: starts_on(made_at),
            entry_price: proposal.limit_price, target_price: proposal.target_price, stop_price: proposal.stop_price,
            reference_close: proposal.reference_close, reference_on: proposal.reference_on, reference_volatility: proposal.reference_volatility, saw_agent_forecast: saw,
            baseline_probability: baseline_for(proposal, horizon, author)).tap do |forecast|
      AuditEvent.log("forecast_recorded", actor: author.to_sym, user: user, subject: forecast,
                     data: { proposal: proposal.id, probability: forecast.probability.to_s, horizon_days: horizon, starts_on: forecast.starts_on.iso8601, saw_agent_forecast: saw })
    end
  end

  # What the levels, the horizon, and the volatility alone imply, frozen with the claim (Research::Baseline).
  def self.baseline_for(proposal, horizon, author)
    Research::Baseline.probability(entry: proposal.limit_price, stop: proposal.stop_price, target: proposal.target_price, volatility: proposal.reference_volatility,
                                   horizon_days: horizon, seed: proposal.id * 2 + (author.to_s == "agent" ? 0 : 1))
  end

  # The database's checks say the same; this says it in words before a constraint fires.
  def self.measurable!(proposal)
    raise Unmeasurable, "a forecast is on an entry" unless proposal.kind_entry?
    raise Unmeasurable, "no stop and target on the proposal" unless proposal.stop_price && proposal.target_price
    raise Unmeasurable, "no final close to measure it from" unless proposal.reference_close
    raise Unmeasurable, "no volatility to set its baseline from" unless proposal.reference_volatility
    raise Unmeasurable, "the stop must sit below the limit and the target above it" unless proposal.stop_price.positive? && proposal.stop_price < proposal.limit_price && proposal.limit_price < proposal.target_price
    return if proposal.stop_price < proposal.reference_close && proposal.reference_close < proposal.target_price
    raise Unmeasurable, "the last close (#{proposal.reference_close.to_s("F")}) is outside the stop and the target, so it would be settled already"
  end

  # The first session whose candle holds no range from before the forecast: today's when made before the regular
  # open (or on a closed day, which has no candle), else the next day's. The candles themselves skip closed days.
  def self.starts_on(made_at)
    local = made_at.in_time_zone(MarketDay::ZONE)
    day = MarketDay.find_by(date: local.to_date)
    return local.to_date if day && !day.trading
    opens = day&.regular_opens_at || local.change(hour: REGULAR_OPEN.first, min: REGULAR_OPEN.last)
    local < opens ? local.to_date : local.to_date + 1
  end

  # The resolver's write: the outcome once, or how far the candles have been read while it stays open. A night
  # that read candles ends a run of failed ones.
  def resolve!(verdict)
    merged = detail.except("failed_nights").merge(verdict.detail)
    return tap { update!(checked_through: verdict.checked_through, detail: merged) } unless verdict.outcome
    transaction do # the outcome and its audit row together: a frozen outcome cannot be written again
      update!(outcome: verdict.outcome, void_reason: verdict.void_reason, resolved_at: Time.current, checked_through: verdict.checked_through, detail: merged)
      AuditEvent.log("forecast_resolved", actor: :system, subject: self, data: { outcome: outcome, void_reason: void_reason, **verdict.detail.symbolize_keys })
    end
    self
  end

  # A night without usable candles: counted, and the void_after-th in a row voids it as data unavailable.
  def record_failed_night!(void_after:)
    nights = detail["failed_nights"].to_i + 1
    give_up = nights >= void_after
    resolve!(Resolution::Verdict.new(outcome: give_up ? "void" : nil, void_reason: give_up ? "data_unavailable" : nil, checked_through: checked_through, detail: { "failed_nights" => nights }))
    outcome || "no_data"
  end

  def outcome_label
    return "open, read through #{checked_through.strftime('%b %-d')}" if outcome.nil? && checked_through
    return "open, from #{starts_on.strftime('%b %-d')}" if outcome.nil?
    return "void: #{void_reason.humanize(capitalize: false)}" if outcome_void?
    [ outcome, *FLAGS.select { |flag| detail[flag] }.map { |flag| flag.humanize(capitalize: false) } ].join(", ")
  end

  def reward_to_risk = (target_price - entry_price) / (entry_price - stop_price)
  # p × reward-to-risk − (1 − p), before costs: information beside the forecast, never a rule.
  def expected_r = probability * reward_to_risk - (1 - probability)
  # The last session the claim can still be open on: the entry window and the horizon, counted in weekdays. A
  # holiday inside it only makes the true end later, so a forecast past this is never cut off early by more than
  # the holidays, and the calibration waits a further week before scoring it.
  def window_ends_on = (Resolution::ENTRY_WINDOW + horizon_days).times.reduce(starts_on - 1) { |day, _| day = day + 1; day += 1 while day.on_weekend?; day }
end
