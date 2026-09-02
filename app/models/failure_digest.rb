# Everything that went wrong in a fixed window ending now: failed feeds, failed or capped agent runs,
# briefs that never left, and jobs the queue gave up on. Token-skipped runs are the nag's business, not
# this one's, and stuck runs are swept to failed before the digest reads.
class FailureDigest
  WINDOW = 24.hours

  def initialize(now: Time.current)
    @since = now - WINDOW
    @now = now
  end

  attr_reader :since, :now

  def sync_failures = @sync_failures ||= SyncRun.where(status: %w[ failed partial ]).where(finished_at: window).includes(:account).recent_first.to_a
  def agent_failures = @agent_failures ||= AgentRun.where(status: %w[ failed capped ]).where(finished_at: window).recent_first.to_a
  def undelivered = @undelivered ||= AgentRun.unemailed.where(finished_at: window).recent_first.to_a
  def failed_jobs = @failed_jobs ||= SolidQueue::FailedExecution.where(created_at: window).includes(:job).order(created_at: :desc).to_a

  def sync_by_feed = sync_failures.group_by { |run| [ run.account&.label, run.feed ].compact.join(" · ") }
  def jobs_by_class = failed_jobs.group_by { |failure| failure.job.class_name }

  def empty? = sync_failures.none? && agent_failures.none? && undelivered.none? && failed_jobs.none?

  private
    def window = since..now
end
