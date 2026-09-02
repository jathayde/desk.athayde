# Everything that went wrong in a fixed window ending now: failed feeds, failed or capped agent runs, briefs
# that never left, jobs the queue gave up on, and submissions that did not go through. A submission still
# unresolved is standing state, listed every day until it is not. Token-skipped runs are the nag's business,
# not this one's, and stuck runs are swept to failed before the digest reads.
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
  def failed_attempts = @failed_attempts ||= SubmissionAttempt.dead.where(updated_at: window).includes(order_proposal: :instrument).order(updated_at: :desc).to_a
  def unresolved_proposals = @unresolved_proposals ||= OrderProposal.submission_unknown.includes(:instrument).order(:id).to_a

  def sync_by_feed = sync_failures.group_by { |run| [ run.account&.label, run.feed ].compact.join(" · ") }
  def jobs_by_class = failed_jobs.group_by { |failure| failure.job.class_name }

  def empty? = sync_failures.none? && agent_failures.none? && undelivered.none? && failed_jobs.none? && failed_attempts.none? && unresolved_proposals.none?

  private
    def window = since..now
end
