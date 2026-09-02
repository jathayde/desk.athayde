module Jobs
  # Daily at 17:15 New York: one email for the last 24 hours of failures, none when there were none.
  class FailureDigestJob < ApplicationJob
    def perform
      AgentRun.sweep_stale!
      SyncRun.sweep_stale!
      digest = FailureDigest.new
      return if digest.empty?
      BriefMailer.failure_digest(digest).deliver_now
    end
  end
end
