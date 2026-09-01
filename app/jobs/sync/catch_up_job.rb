module Sync
  # Runs after every re-auth: every feed, bypassing due checks, with windows that cover the pause. Feeds land in step 5.
  class CatchUpJob < ApplicationJob
    def perform
    end
  end
end
