# What the research screen and the Sunday email read (docs/phase-2.6-plan.md §3): the latest stored calibration
# snapshots, and whether they are this week's, and the hypotheses with how many have been tested. A snapshot older than a week is shown with its date as the
# last computed, never as current.
class Research::Digest
  FRESH = 6.days

  def initialize(as_of: MarketDay.today) = @as_of = as_of

  def snapshots = @snapshots ||= CalibrationSnapshot.latest.to_a
  def headlines = snapshots.select { it.scope_author? || it.scope_paired? }
  def computed_on = snapshots.first&.as_of
  def current? = computed_on.present? && computed_on >= @as_of - FRESH
  def open_forecasts = Forecast.open.count
  def hypotheses = @hypotheses ||= Hypothesis.includes(:setup, :parent).newest_first.to_a
  def tests = @tests ||= Hypothesis.ever_tested.count
  def bar = Hypothesis.bar(tests)
  def awaiting_decision = hypotheses.select { it.status_testing? && it.ready? }
end
