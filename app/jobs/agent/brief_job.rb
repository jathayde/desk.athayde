module Agent
  # The shared shape of a scheduled brief: one run per kind and market day, sweep what a killed worker left,
  # skip a closed day with a row that says so, let the 07:00 syncs land, run, then deliver whatever the run
  # produced. A mail failure never costs a second API run: the row is saved first and can be resent.
  class BriefJob < ApplicationJob
    WAIT_FOR_SYNC = 90.seconds
    POLL = 5.seconds
    WAITED_FEEDS = SyncRun::ACCOUNT_FEEDS + [ :memory_repo ]

    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform(date = MarketDay.today)
      AgentRun.sweep_stale!
      return if AgentRun.served?(kind, date)
      day = MarketDay.for(date)
      return AgentRun.create!(kind: kind, market_date: date, status: :skipped, started_at: Time.current, finished_at: Time.current, error: "market closed") unless day.trading?
      run = AgentRun.create!(kind: kind, market_date: date, status: :running, started_at: Time.current)
      wait_for_sync
      converse(run)
      run.deliver!
    end

    private
      def kind = raise(NotImplementedError)

      # Whatever raises, the row ends failed with the reason and the email still goes out before the queue hears about it.
      def converse(run)
        Agent::Run.new(run).perform
      rescue StandardError => e
        run.finish!(:failed, error: "#{e.class}: #{e.message.truncate(300)}") if run.reload.running?
        run.deliver!
        raise
      end

      # A brief reading positions mid-upsert, or memory files mid-pull, would see mixed stamps; give live runs a bounded head start.
      def wait_for_sync
        deadline = Time.current + WAIT_FOR_SYNC
        while SyncRun.live.where(feed: WAITED_FEEDS).exists? && Time.current < deadline
          sleep POLL
        end
      end
  end
end
