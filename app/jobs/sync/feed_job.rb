module Sync
  # Shared shape of the per-account feeds: a client, the account hash, the cursor window, and the gap audit.
  class FeedJob < ApplicationJob
    LOOKBACK = 364.days # live probe 2026-09-01: orders and transactions accept a one-year window; a day inside it for safety

    private
      def client = Schwab.client

      # Cursor: from the last advanced window, overlapping by `overlap`; capped at the lookback. When the
      # cursor is older than the lookback, Schwab cannot return the gap and the run says so.
      def window_for(feed, account, overlap:)
        now = Time.current
        cursor = SyncRun.last_window_to(feed, account)
        floor = now - LOOKBACK
        from = cursor ? [ cursor - overlap, floor ].max : floor
        gap_from = cursor if cursor && cursor < floor
        [ from, now.utc.end_of_day, gap_from ]
      end

      # Audited once per gap, not once per run.
      def note_gap(run, gap_from, account)
        return unless gap_from
        run.update!(gap_from: gap_from)
        return if AuditEvent.where(kind: "sync_gap_unrecoverable", subject: account).where("data->>'feed' = ? AND data->>'gap_from' = ?", run.feed, gap_from.iso8601).exists?
        AuditEvent.log("sync_gap_unrecoverable", actor: :system, subject: account, data: { feed: run.feed, gap_from: gap_from.iso8601, lookback_days: LOOKBACK.in_days.to_i })
      end
  end
end
