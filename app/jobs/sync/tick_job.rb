module Sync
  # The only scheduled sync entry point. Refreshes the calendar, checks the token once, and enqueues what is due.
  class TickJob < ApplicationJob
    INTRADAY = { positions: 15.minutes, orders: 5.minutes, activities: 5.minutes }.freeze
    OFF_HOURS = 60.minutes
    CALENDAR_DAYS = 7

    def perform
      refresh_calendar
      return pause! unless SchwabToken.usable?

      in_session = MarketDay.session_open?
      Account.find_each do |account|
        intraday = in_session && account.trading_enabled?
        INTRADAY.each do |feed, interval|
          every = intraday ? interval : OFF_HOURS
          next unless SyncRun.due?(feed, account, every: every)
          job_for(feed).perform_later(account)
        end
      end
    end

    private
      def refresh_calendar
        today = MarketDay.today
        (today..today + CALENDAR_DAYS).each { |date| MarketDay.for(date) }
      end

      # One skipped row per hour and one audit per episode; nothing is enqueued, so the queue cannot grow.
      # The settings row lock serializes this against issue!, so a re-auth landing mid-tick cannot be marked paused.
      def pause!
        reason = SystemSettings.transaction do
          settings = SystemSettings.instance.lock!
          next nil if SchwabToken.usable?
          unless settings.sync_paused_reason
            settings.update!(sync_paused_reason: "Schwab token unusable; re-authenticate")
            AuditEvent.log("sync_paused_token_expired", actor: :system)
          end
          settings.sync_paused_reason
        end
        return if reason.nil? || SyncRun.where(status: :skipped_token, started_at: 1.hour.ago..).exists?
        SyncRun.create!(feed: :positions, status: :skipped_token, started_at: Time.current, finished_at: Time.current, error: reason)
      end

      def job_for(feed) = { positions: PositionsJob, orders: OrdersJob, activities: ActivitiesJob }.fetch(feed)
  end
end
