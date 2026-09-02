module Agent
  # Phase 1 stub: no API call. The Sunday email is the re-auth link, token age, sync health, job failures,
  # and the stored setup stats; it records a run row so the system page and the digest can see it.
  class SundayReviewJob < ApplicationJob
    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform(date = MarketDay.today)
      return if AgentRun.served?(:sunday_review, date)
      AgentRun.create!(kind: :sunday_review, market_date: date, status: :succeeded, started_at: Time.current, finished_at: Time.current).deliver!
    end
  end
end
