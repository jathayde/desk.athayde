# One row per feed run. Wraps the work so token loss, Schwab failures, and quarantined records all
# land as a status; anything else is recorded as failed and re-raised so the queue sees it too.
class SyncRun < ApplicationRecord
  STALE_AFTER = 10.minutes # a running row older than this is a crashed or restarted worker, not a run
  ACCOUNT_FEEDS = %i[ positions orders activities ].freeze

  belongs_to :account, optional: true

  enum :feed, {
    accounts: "accounts", positions: "positions", orders: "orders", activities: "activities",
    market_hours: "market_hours", memory_repo: "memory_repo", snapshots: "snapshots"
  }, prefix: true
  enum :status, { running: "running", succeeded: "succeeded", partial: "partial", failed: "failed", skipped_token: "skipped_token" }

  scope :recent_first, -> { order(started_at: :desc) }
  scope :for, ->(feed, account) { where(feed: feed, account: account) }
  scope :advanced_cursor, -> { where(status: %w[ succeeded partial ]) }
  scope :live, -> { running.where(started_at: STALE_AFTER.ago..) }
  scope :stale_running, -> { running.where(started_at: ..STALE_AFTER.ago) }

  # A worker killed mid-feed leaves a running row; the tick and the digest both sweep it so the system page and
  # the digest see a failure, not a run that never ends.
  def self.sweep_stale!
    stale_running.find_each { |run| run.finish!(:failed, error: "left running") }
  end

  def self.record(feed, account: nil, window_from: nil, window_to: nil)
    run = create!(feed: feed, account: account, status: :running, started_at: Time.current, window_from: window_from, window_to: window_to)
    outcome = yield run
    run.finish!(outcome == :failed ? :failed : (outcome == :partial || run.unmapped_values.any? ? :partial : :succeeded), error: run.error)
  rescue Schwab::NoUsableToken, Schwab::AuthError => e
    run.finish!(:skipped_token, error: e.message)
  rescue Schwab::Error => e
    run.finish!(:failed, error: e.message)
  rescue StandardError => e
    run.finish!(:failed, error: "#{e.class}: #{e.message}")
    raise
  ensure
    run&.finish!(:failed, error: "left running") if run&.running? && !run.destroyed?
  end

  def self.last_window_to(feed, account) = self.for(feed, account).advanced_cursor.maximum(:window_to)
  def self.last_started_at(feed, account) = self.for(feed, account).maximum(:started_at)
  def self.running?(feed, account) = self.for(feed, account).live.exists?

  # Due when nothing is live and the last start is older than the interval, with a minute of slack for cron drift.
  def self.due?(feed, account, every:)
    return false if running?(feed, account)
    last = last_started_at(feed, account)
    last.nil? || last <= (every - 1.minute).ago
  end

  def finish!(status, error: nil)
    update!(status: status, finished_at: Time.current, error: error&.truncate(1000))
    self
  end

  def touched(count) = update!(records_touched: records_touched.to_i + count)

  def quarantine(key, detail)
    unmapped_values[key.to_s] = Array(unmapped_values[key.to_s]) << detail
    save!
  end
end
