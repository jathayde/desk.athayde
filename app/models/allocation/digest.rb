# What the Sunday review says about the book (docs/phase-2.5-plan.md §2): the stored drift, cash-drag, correlation,
# and fund-flow rows, read and never recomputed, and only this week's as this week's: a row older than a week is
# shown with its date as the last measured, and never flags anything "right now". A diversifier is flagged when
# its correlation with SPY is above the correlation rule's threshold.
class Allocation::Digest
  FRESH = 6.days

  def initialize(as_of: MarketDay.today) = @as_of = as_of

  def drifts = @drifts ||= Allocation::Drift.current.to_a
  def cash_drag = @cash_drag ||= CashDragDiagnostic.order(as_of: :desc).first
  def cash_drag_current? = cash_drag.present? && fresh?(cash_drag.as_of)

  # The latest run's rows at the rule's window; the run's audit row names what it could not measure.
  def correlations
    @correlations ||= begin
      run_on = last_correlation_check&.data&.dig("as_of")&.then { Date.parse(it) }
      run_on ? Correlation.where(as_of: run_on, window_days: last_correlation_check.data["window_days"]).includes(instrument: :tags).order(value: :desc).to_a : []
    end
  end

  def correlations_current? = last_correlation_check.present? && fresh?(Date.parse(last_correlation_check.data["as_of"]))
  def unmeasured = Hash(last_correlation_check&.data&.dig("skipped"))
  def threshold = @threshold ||= RiskRule.active_for("correlation_threshold")&.then { |rule| BigDecimal(rule.param(:value).to_s) }
  def flagged = threshold && correlations_current? ? correlations.select { |row| row.diversifier? && row.value > threshold } : []
  def fund_flow = @fund_flow ||= FundFlow.latest
  def deployments = @deployments ||= CashInflow.committing.includes(:tranches, :activity).order(:id).to_a
  def open_reviews = @open_reviews ||= ThesisReview.open.includes(:instrument, cash_inflow: :activity).order(:created_at).to_a
  def last_drift_check = @last_drift_check ||= AuditEvent.where(kind: "allocation_drift_checked").order(:created_at).last
  def last_correlation_check = @last_correlation_check ||= AuditEvent.where(kind: "correlation_checked").order(:created_at).last

  private
    def fresh?(date) = date >= @as_of - FRESH
end
