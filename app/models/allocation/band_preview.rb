# What last night's drift rows would say under a candidate rebalance band (docs/phase-2.5-plan.md §3): each target
# re-judged against the wider of the candidate band and its one-share floor, from the stored row. Reads; writes
# nothing; never asks Schwab.
class Allocation::BandPreview
  Row = Data.define(:drift, :band, :before, :after)
  attr_reader :rule, :candidate

  def initialize(rule, params:)
    @rule = rule
    @candidate = RiskRule.new(rule_type: rule.rule_type, params: params, version: rule.version + 1)
  end

  def valid? = candidate.valid?

  # Every measured row: whether the band would have put it outside, whatever was then done about it.
  def rows
    return [] unless valid?
    @rows ||= Allocation::Drift.current.not_action_unavailable.where.not(drift: nil).map do |drift|
      band = [ candidate_band, BigDecimal(drift.detail["one_share"] || "0") ].max
      Row.new(drift: drift, band: band, before: drift.action, after: drift.drift.abs > band ? "reported" : "none")
    end
  end

  private
    def candidate_band = @candidate_band ||= BigDecimal(candidate.param(:percent).to_s) / 100
end
