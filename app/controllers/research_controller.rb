# The research screen (docs/phase-2.6-plan.md §3): the stored calibration figures, and in later steps the
# hypotheses. Reads rows only.
class ResearchController < ApplicationController
  def show
    @research = Research::Digest.new
    @setups = Setup.active.order(:name)
    @new_hypothesis = Hypothesis.new(holdout_from: MarketDay.today, min_sample: 30)
  end
end
