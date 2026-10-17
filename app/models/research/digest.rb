# What the research screen and the Sunday email read about calibration (docs/phase-2.6-plan.md §3): the latest
# stored snapshots, and whether they are this week's. A snapshot older than a week is shown with its date as the
# last computed, never as current.
class Research::Digest
  FRESH = 6.days

  def initialize(as_of: MarketDay.today) = @as_of = as_of

  def snapshots = @snapshots ||= CalibrationSnapshot.latest.to_a
  def headlines = snapshots.select { it.scope_author? || it.scope_paired? }
  def computed_on = snapshots.first&.as_of
  def current? = computed_on.present? && computed_on >= @as_of - FRESH
  def open_forecasts = Forecast.open.count
end
