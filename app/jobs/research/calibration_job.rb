module Research
  # Saturday 08:15 New York, after the diagnostics: the calibration snapshots (docs/phase-2.6-plan.md §0.3, §2), from
  # stored forecasts only. Weekly, since a handful of forecasts a week moves nothing nightly. Reads and writes rows.
  class CalibrationJob < ApplicationJob
    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform(as_of = MarketDay.today) = CalibrationSnapshot.record!(as_of: as_of)
  end
end
