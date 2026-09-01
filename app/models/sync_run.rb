class SyncRun < ApplicationRecord
  enum :feed, {
    accounts: "accounts", positions: "positions", balances: "balances", orders: "orders",
    activities: "activities", market_hours: "market_hours", memory_repo: "memory_repo", snapshots: "snapshots"
  }, prefix: true
  enum :status, { running: "running", succeeded: "succeeded", partial: "partial", failed: "failed", skipped_token: "skipped_token" }

  scope :recent_first, -> { order(started_at: :desc) }
end
