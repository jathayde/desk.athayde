module Research
  # Saturday 08:20 New York, after the calibration: a decay check for each accepted hypothesis that has one due
  # (docs/phase-2.6-plan.md §0.7, §2). Rows only; one hypothesis's failure never holds up the rest.
  class DecayJob < ApplicationJob
    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform(as_of = MarketDay.today)
      Hypothesis.status_accepted.includes(:setup).find_each do |hypothesis|
        DecayCheck.record!(hypothesis, as_of: as_of)
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { job: self.class.name, hypothesis: hypothesis.id })
      end
    end
  end
end
