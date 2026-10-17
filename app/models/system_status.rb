# The operations page's read model: the desk's own token, halt, and pause facts, plus feeds per account,
# failures, holdings, briefs, and accounts needing setup.
class SystemStatus
  FeedRow = Data.define(:account, :feed, :latest, :last_success)
  AccountRow = Data.define(:account, :equity, :symbols)

  def desk = @desk ||= Desk.new
  delegate :settings, :token, :token_status, :halted_by, :sync_paused_since, to: :desk

  def next_sunday_email = SchwabToken.next_sunday_email
  def token_dies_before_sunday? = token && token.refresh_expires_at < next_sunday_email

  def accounts
    @accounts ||= Account.order(:id).includes(:current_balance, positions: :instrument).map do |account|
      AccountRow.new(account: account, equity: account.current_balance&.equity, symbols: account.positions.first(3).map { |p| p.instrument.symbol })
    end
  end

  # Shadow mode's evidence: approvals recorded, and how many the operator's hand-placed orders matched.
  def shadowed_approvals = @shadowed_approvals ||= OrderProposal.where(shadow: true).where.not(status: %w[ submitting ]).count
  def shadow_reconciled = @shadow_reconciled ||= OrderProposal.where(shadow: true).where.not(broker_order_id: nil).count
  def awaiting_hand_placement = @awaiting_hand_placement ||= OrderProposal.awaiting_hand_placement.count
  def holdings = @holdings ||= Position.joins(:account, :instrument).merge(Account.trading).includes(:instrument).order("instruments.symbol").to_a

  def feed_rows
    @feed_rows ||= accounts.flat_map do |row|
      SyncRun::ACCOUNT_FEEDS.map do |feed|
        FeedRow.new(account: row.account, feed: feed, latest: SyncRun.for(feed, row.account).recent_first.first, last_success: row.account.last_sync(feed))
      end
    end
  end

  def gaps = SyncRun.where.not(gap_from: nil).recent_first.limit(5)
  def failed_run_count = SyncRun.failed.where(started_at: 7.days.ago..).count
  def failed_runs_sample = SyncRun.failed.where(started_at: 7.days.ago..).recent_first.limit(5)
  def failed_job_count = SolidQueue::FailedExecution.where(created_at: 7.days.ago..).count
  def api_spend_this_month = AgentRun.this_month.sum(:estimated_cost)
  def skeptic_runs_this_month = AgentRun.skeptic.this_month
  def agent_runs = @agent_runs ||= AgentRun.where.not(kind: :skeptic).recent_first.limit(5) # the briefs; the skeptic's are counted on their own line
  def unpriced_runs? = AgentRun.this_month.where(estimated_cost: nil).where.not(model: nil).where.not(status: :skipped).exists?
  def memory_repo = @memory_repo ||= Memory::Repo.configured
  def memory_run = @memory_run ||= SyncRun.feed_memory_repo.recent_first.first
end
