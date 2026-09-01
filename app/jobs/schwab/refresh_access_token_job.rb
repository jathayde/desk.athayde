module Schwab
  class RefreshAccessTokenJob < ApplicationJob
    queue_as :critical

    def perform
      token = SchwabToken.current
      return unless token&.usable?
      token.refresh!
    rescue Schwab::Error
      # Recorded on the token row and, for a revocation, in audit_events and the pause reason.
    end
  end
end
