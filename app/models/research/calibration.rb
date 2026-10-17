# Whether the forecasts mean anything (docs/phase-2.6-plan.md §0.3): per cut, the Brier score of the scored
# forecasts against two baselines. The baseline that matters is each forecast's own Research::Baseline, what its
# levels, horizon, and volatility imply under the resolver's rules; a forecaster who cannot beat it has said
# nothing the levels and the tape did not. The hindsight Brier is the best constant on the same sample, shown and
# labelled as such. Skill against the baseline carries a bootstrap interval drawn by week, and a cut is "not
# distinguishable from the baseline" until the interval clears zero. Computed from rows by the Saturday job and
# stored; never on a page render, never in the proposing agent's prompt.
#
# What is scored: a forecast whose latest possible window has closed (and a week more for holidays), so a cut is
# never flattered by its fast hits and stops while its slow expiries are still open; one forecast per bet, the first
# of each author's on a name whose planned windows overlap; one per proposal where the authors are mixed, the
# agent's; and nothing at all below the floor, where only the counts are stored.
class Research::Calibration
  BRIER_FLOOR = 20
  RELIABILITY_FLOOR = 50
  BUCKETS = 5 # quintiles: from RELIABILITY_FLOOR, every bucket holds at least ten
  MATURING = 7.days
  AUTHOR_LABELS = { "agent" => "Agent", "human" => "Operator" }.freeze

  Cut = Data.define(:scope, :key, :label, :forecasts, :extra) do
    def initialize(scope:, key:, label:, forecasts:, extra: {}) = super
  end

  def initialize(forecasts = Forecast.includes(order_proposal: :setup).order(:id).to_a, as_of: MarketDay.today)
    @forecasts, @as_of = forecasts, as_of
  end

  def cuts = [ overall, *author_cuts, *paired_cuts, *setup_cuts ]

  def figures(cut)
    counted = cut.scope == "paired" ? cut.forecasts : first_of_each_bet(cut.forecasts) # a pair was kept or dropped whole already
    scored = counted.select { scored?(it) }
    figures = { "n" => scored.size, "open" => cut.forecasts.count { it.outcome.nil? }, "maturing" => counted.count { it.outcome.present? && !mature?(it) && !it.outcome_void? },
                "overlapping" => cut.forecasts.reject(&:outcome_void?).size - counted.size, "voids" => cut.forecasts.select(&:outcome_void?).group_by(&:void_reason).transform_values(&:size),
                "instruments" => scored.map { it.order_proposal.instrument_id }.uniq.size, "floors" => { "brier" => BRIER_FLOOR, "reliability" => RELIABILITY_FLOOR }, **cut.extra }
    scored.size >= BRIER_FLOOR ? figures.merge(round_figures(scores(scored))) : figures
  end

  private
    attr_reader :forecasts, :as_of

    def overall = Cut.new(scope: "overall", key: "all", label: "All forecasts, one per proposal", forecasts: one_per_proposal(forecasts))

    # The operator's forecast is optional, so its cut also says how many of the operator's entries carry one.
    def author_cuts
      AUTHOR_LABELS.map do |author, label|
        Cut.new(scope: "author", key: author, label: label, forecasts: forecasts.select { it.author == author }, extra: author == "human" ? { "coverage" => coverage } : {})
      end
    end

    # Both authors on the same proposal from the same session, both scored, the operator's made blind: the only
    # fair comparison, since the operator's forecast is optional and picks its own cases. A pair is one bet, kept
    # or dropped whole by the overlap rule, and the agent's row carries the difference between the two.
    def paired_cuts
      pairs = forecasts.group_by(&:order_proposal_id).values.filter_map do |rows|
        agent, human = rows.find(&:author_agent?), rows.find(&:author_human?)
        [ agent, human ] if agent && human && agent.starts_on == human.starts_on && scored?(agent) && scored?(human)
      end
      anchored = pairs.count { |_, human| human.saw_agent_forecast }
      blind = pairs.reject { |_, human| human.saw_agent_forecast }
      kept = first_of_each_bet(blind.map(&:first)).to_set
      blind = blind.select { |agent, _| kept.include?(agent) }
      extra = { "anchored_excluded" => anchored }
      [ Cut.new(scope: "paired", key: "agent", label: "Agent, paired", forecasts: blind.map(&:first), extra: extra.merge(head_to_head(blind))),
        Cut.new(scope: "paired", key: "human", label: "Operator, paired", forecasts: blind.map(&:last), extra: extra) ]
    end

    # By the setup the proposal named when it was made, never the one the journal assigns later.
    def setup_cuts
      one_per_proposal(forecasts).group_by { it.order_proposal.setup }.sort_by { |setup, _| setup&.name.to_s }.map do |setup, rows|
        Cut.new(scope: "setup", key: setup&.id&.to_s || "none", label: setup&.name || "No setup", forecasts: rows)
      end
    end

    def one_per_proposal(rows) = rows.group_by(&:order_proposal_id).values.map { |group| group.find(&:author_agent?) || group.first }

    def coverage
      entries = OrderProposal.kind_entry.where(origin: "human")
      { "entries" => entries.count, "forecast" => entries.where(id: Forecast.author_human.select(:order_proposal_id)).count }
    end

    # The operator's squared error less the agent's, per pair: below zero, the operator was closer.
    def head_to_head(pairs)
      return {} if pairs.size < BRIER_FLOOR
      differences = pairs.map { |agent, human| error(human) - error(agent) }
      { "operator_minus_agent" => Research::Stats.mean(differences).round(4),
        "operator_minus_agent_interval" => round_figures(Research::Stats.bootstrap_interval(differences, clusters: pairs.map { week(it.first) })) }
    end

    def scored?(forecast) = forecast.outcome.present? && !forecast.outcome_void? && mature?(forecast)
    def mature?(forecast) = forecast.window_ends_on + MATURING < as_of
    def outcome(forecast) = forecast.outcome_hit? ? 1.0 : 0.0
    def error(forecast) = (forecast.probability.to_f - outcome(forecast))**2
    def week(forecast) = forecast.starts_on.beginning_of_week

    # Per author and name, in the order made, over every forecast that is not void: one whose window opens inside
    # the planned window of the last counted one on the same name is the same bet again, and is counted once. The
    # planned window, not the resolved one, so whether the next bet counts never depends on how the first ended.
    def first_of_each_bet(rows)
      rows.reject(&:outcome_void?).group_by { [ it.author, it.order_proposal.instrument_id ] }.values.flat_map do |bets|
        bets.sort_by { [ it.starts_on, it.id ] }.each_with_object([]) { |row, kept| kept << row unless kept.last && row.starts_on <= kept.last.window_ends_on }
      end
    end

    def scores(scored)
      outcomes = scored.map { outcome(it) }
      forecast = scored.map { it.probability.to_f }
      baseline = scored.map { it.baseline_probability.to_f }
      brier = scored.map { error(it) }
      against = outcomes.zip(baseline).map { |o, b| (b - o)**2 }
      skill = against.zip(brier).map { |b, f| b - f }
      hit_rate = Research::Stats.mean(outcomes)
      ambiguous = scored.count { it.detail["ambiguous"] }
      scores = { "hit_rate" => hit_rate, "hit_rate_if_ambiguous_hit" => (outcomes.sum + ambiguous) / scored.size, "ambiguous" => ambiguous,
                 "expired" => scored.count { it.detail["expired"] }, "mean_probability" => Research::Stats.mean(forecast), "mean_baseline" => Research::Stats.mean(baseline),
                 "mean_reward_to_risk" => Research::Stats.mean(scored.map { it.reward_to_risk.to_f }),
                 "brier" => Research::Stats.mean(brier), "baseline_brier" => Research::Stats.mean(against), "hindsight_brier" => hit_rate * (1 - hit_rate),
                 "skill" => Research::Stats.mean(skill), "skill_interval" => Research::Stats.bootstrap_interval(skill, clusters: scored.map { week(it) }) }
      scores["reliability"] = reliability(scored) if scored.size >= RELIABILITY_FLOOR
      scores
    end

    # Quintiles by forecast, ties broken by id so the split is reproducible: mean forecast against the observed rate.
    def reliability(scored)
      ordered = scored.sort_by { [ it.probability, it.id ] }
      size, extra = ordered.size.divmod(BUCKETS)
      Array.new(BUCKETS) { |i| ordered.shift(size + (i < extra ? 1 : 0)) }.map do |bucket|
        hits = bucket.count(&:outcome_hit?)
        low, high = Research::Stats.wilson(hits, bucket.size)
        { "n" => bucket.size, "mean_probability" => Research::Stats.mean(bucket.map { it.probability.to_f }), "observed" => hits.to_f / bucket.size, "low" => low, "high" => high }
      end
    end

    def round_figures(value)
      case value
      when Float then value.round(4)
      when Array then value.map { round_figures(it) }
      when Hash then value.transform_values { round_figures(it) }
      else value
      end
    end
end
