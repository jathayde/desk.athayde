# One cut's calibration figures as of a Saturday (docs/phase-2.6-plan.md §0.3), read by /research and the Sunday
# email, never recomputed there. The floors decide what a page may show: a Brier score from BRIER_FLOOR scored
# forecasts, the reliability table from RELIABILITY_FLOOR.
class CalibrationSnapshot < ApplicationRecord
  SCOPES = %w[ overall author paired setup ].freeze

  enum :scope, SCOPES.index_by(&:itself), prefix: true, validate: true
  store_accessor :figures, :brier, :baseline_brier, :hindsight_brier, :skill, :skill_interval, :hit_rate, :hit_rate_if_ambiguous_hit, :mean_probability,
                 :mean_baseline, :mean_reward_to_risk, :reliability, :coverage, :operator_minus_agent, :operator_minus_agent_interval

  scope :latest, -> { where(as_of: maximum(:as_of)).in_order_of(:scope, SCOPES).order(:label) }

  # Every cut, written in one transaction with one audit row; a rerun on the same day replaces that day's rows.
  def self.record!(as_of: MarketDay.today)
    forecasts = Forecast.includes(order_proposal: :setup).order(:id).to_a
    calibration = Research::Calibration.new(forecasts, as_of: as_of)
    cuts = calibration.cuts
    transaction do
      where(as_of: as_of).delete_all
      cuts.each { |cut| create!(as_of: as_of, scope: cut.scope, key: cut.key, label: cut.label, figures: calibration.figures(cut)) }
      AuditEvent.log("calibration_computed", actor: :system, data: { as_of: as_of.iso8601, cuts: cuts.size, forecasts: forecasts.size })
    end
  end

  %w[ n open maturing overlapping instruments ambiguous expired anchored_excluded ].each { |key| define_method(key) { figures[key].to_i } }
  def voids = figures["voids"].to_h
  def floor(name) = figures.dig("floors", name.to_s) || Research::Calibration.const_get("#{name.upcase}_FLOOR") # the floor the row was computed under
  def scored? = brier.present?
  def reliability? = reliability.present?
  def verdict
    return "not enough forecasts yet (#{n} scored; #{floor(:brier)} needed)" unless scored?
    return "too few weeks to tell (#{figures["weeks"]} weeks; #{floor(:weeks)} needed)" unless skill_interval
    clears(skill_interval, "the baseline")
  end

  # The paired head-to-head, carried on the agent's row: below zero, the operator was closer.
  def head_to_head_verdict
    return nil unless operator_minus_agent
    return "too few weeks to compare the two" unless operator_minus_agent_interval
    { "better" => "the agent closer than the operator", "worse" => "the operator closer than the agent" }.fetch(direction(operator_minus_agent_interval), "agent and operator not distinguishable")
  end

  private
    def clears(interval, against) = direction(interval).then { it ? "#{it} than #{against}" : "not distinguishable from #{against}" }

    # Which side of zero an interval sits on: above is "better", below "worse", across it nil.
    def direction(interval)
      low, high = interval
      return "better" if low > 0
      "worse" if high < 0
    end
end
