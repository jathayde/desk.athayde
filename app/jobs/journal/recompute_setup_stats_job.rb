module Journal
  class RecomputeSetupStatsJob < ApplicationJob
    def perform(setup) = setup.recompute_stats!
  end
end
