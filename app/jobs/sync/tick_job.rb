module Sync
  # The only scheduled sync entry point. Refreshes the calendar, checks the token once, and enqueues what is due.
  class TickJob < ApplicationJob
    INTRADAY = { positions: 15.minutes, orders: 5.minutes, activities: 5.minutes }.freeze
    OFF_HOURS = 60.minutes
    CALENDAR_DAYS = 7
    SNAPSHOT_DELAY = 20.minutes

    def perform
      SyncRun.sweep_stale!
      refresh_calendar
      return pause! unless SchwabToken.usable?

      in_session = MarketDay.session_open?
      Account.find_each do |account|
        INTRADAY.each_key do |feed|
          next unless SyncRun.due?(feed, account, every: account.sync_interval(feed, in_session: in_session))
          job_for(feed).perform_later(account)
        end
        Snapshots::DailyJob.perform_later(account, today) if snapshot_due?(account, today)
      end
    end

    private
      # Once per Schwab-sourced market day, 20 minutes after the regular close, after positions and orders both synced
      # since the close: the risk columns are written once and read stops.
      def snapshot_due?(account, date)
        day = MarketDay.find_by(date: date)
        return false unless account.trading_enabled? && day&.schwab? && day.trading? && Time.current >= day.regular_closes_at + SNAPSHOT_DELAY
        return false if account.snapshots.exists?(as_of: date)
        %i[ positions orders ].all? { |feed| SyncRun.for(feed, account).advanced_cursor.where(started_at: day.regular_closes_at..).exists? }
      end

      def today = MarketDay.today

      def refresh_calendar
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
