# The operations page's read model: token, feeds per account, failures, and accounts needing setup.
class SystemStatus
  FeedRow = Data.define(:account, :feed, :latest, :last_success)
  AccountRow = Data.define(:account, :equity, :symbols)

  def settings = @settings ||= SystemSettings.instance
  def token = @token ||= SchwabToken.current
  def token_status = SchwabToken.status(token)
  def next_sunday_email = SchwabToken.next_sunday_email
  def token_dies_before_sunday? = token && token.refresh_expires_at < next_sunday_email
  def halted_by = @halted_by ||= AuditEvent.where(kind: "manual_halt_set").order(created_at: :desc).first

  def accounts
    @accounts ||= Account.order(:id).includes(:current_balance, positions: :instrument).map do |account|
      AccountRow.new(account: account, equity: account.current_balance&.equity, symbols: account.positions.first(3).map { |p| p.instrument.symbol })
    end
  end

  def feed_rows
    @feed_rows ||= accounts.flat_map do |row|
      SyncRun::ACCOUNT_FEEDS.map do |feed|
        runs = SyncRun.for(feed, row.account)
        FeedRow.new(account: row.account, feed: feed, latest: runs.recent_first.first, last_success: runs.advanced_cursor.maximum(:finished_at))
      end
    end
  end

  def gaps = SyncRun.where.not(gap_from: nil).recent_first.limit(5)
  def failed_run_count = SyncRun.failed.where(started_at: 7.days.ago..).count
  def failed_runs_sample = SyncRun.failed.where(started_at: 7.days.ago..).recent_first.limit(5)
  def failed_job_count = SolidQueue::FailedExecution.where(created_at: 7.days.ago..).count
  def sync_paused_since = SyncRun.skipped_token.where(started_at: (token&.issued_at || Time.at(0))..).minimum(:started_at)
end
