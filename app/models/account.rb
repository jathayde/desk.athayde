class Account < ApplicationRecord
  has_many :positions, dependent: :destroy
  has_many :balances, dependent: :destroy
  has_one :current_balance, -> { order(as_of: :desc) }, class_name: "Balance"
  has_many :orders, dependent: :restrict_with_exception
  has_many :activities, dependent: :restrict_with_exception
  has_many :trades, dependent: :restrict_with_exception
  has_many :snapshots, dependent: :restrict_with_exception
  has_many :order_proposals, dependent: :restrict_with_exception
  has_many :thesis_reviews, dependent: :restrict_with_exception
  has_many :cash_inflows, dependent: :restrict_with_exception

  enum :account_type, { taxable: "taxable", ira: "ira" }

  validates :schwab_hash, uniqueness: true
  validate :only_taxable_accounts_trade

  scope :trading, -> { where(trading_enabled: true) }
  scope :needing_setup, -> { where(account_type: nil) }

  def needs_setup? = account_type.nil?
  def label = nickname.presence || account_type&.titleize || "Account #{id}"

  # The interval the tick would use for this account and feed right now; views and scheduler share it.
  # Views pass in_session from the known calendar so a page render never fetches from Schwab.
  def sync_interval(feed, in_session: MarketDay.known_session_open?)
    trading_enabled? && in_session ? Sync::TickJob::INTRADAY.fetch(feed.to_sym) : Sync::TickJob::OFF_HOURS
  end

  def last_sync(feed) = SyncRun.for(feed, self).advanced_cursor.maximum(:finished_at)
  def last_sync_failure(feed) = SyncRun.for(feed, self).failed.recent_first.first

  # Operator setup: what the account is and whether the journal follows it. Enabling kicks off a sync
  # immediately rather than waiting up to an hour for the tick.
  def configure!(account_type:, trading_enabled:, nickname:, user:)
    was_enabled = self.trading_enabled?
    update!(account_type: account_type, trading_enabled: trading_enabled, nickname: nickname.presence)
    AuditEvent.log("account_configured", actor: :human, user: user, subject: self, data: { account_type: account_type, trading_enabled: trading_enabled, nickname: nickname.presence })
    if trading_enabled && !was_enabled
      Sync::PositionsJob.perform_later(self)
      Sync::OrdersJob.perform_later(self, working_pass: true)
      Sync::ActivitiesJob.perform_later(self)
    end
    self
  end

  private
    def only_taxable_accounts_trade
      errors.add(:trading_enabled, "is only for the taxable account") if trading_enabled? && !taxable?
    end
end
