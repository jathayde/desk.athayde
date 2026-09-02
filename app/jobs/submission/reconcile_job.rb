# An unknown submission is resolved only by looking (docs/phase-2-plan.md §0.7): after a quiet period, sync
# the orders feed and search; exactly one unlinked match links it, two stay with the operator and are looked
# at again, and nothing found is believed only when the sync itself was whole and a second look ten minutes
# later agrees. A look that could not see (a failed, partial, or quarantining sync) counts for nothing.
class Submission::ReconcileJob < ApplicationJob
  QUIET_PERIOD = 60.seconds
  CONFIRMATION_GAP = 10.minutes
  REAL_WINDOW = 15.minutes
  ORDER_QUARANTINES = %w[ orders_unmapped orders_unresolved ].freeze

  limits_concurrency to: 1, key: ->(proposal) { "reconcile-#{proposal.instrument_id}" }, on_conflict: :discard
  retry_on ActiveRecord::Deadlocked, ActiveRecord::RecordNotUnique, wait: 1.minute, attempts: 3 # a database race is not a verdict

  def perform(proposal)
    return unless proposal.submission_unknown?
    attempt = proposal.submission_attempts.unknown.first or return
    return look_again(proposal) if SyncRun.running?(:orders, proposal.account) # the scheduled sync has the feed; look after it
    run = Sync::OrdersJob.perform_now(proposal.account)
    attempt.looked!(could_see: whole?(run))
    matcher = Submission::Matcher.new(proposal, attempt, window: REAL_WINDOW)
    if (order = matcher.match)
      OrderProposal.transaction do
        order.update!(order_proposal: proposal, placed_via: :app)
        proposal.record_reconciled!(attempt, order: order)
      end
    elsif matcher.ambiguous?
      attempt.ambiguous!(matcher.candidates) # the operator resolves it at Schwab; the next look may find one
      look_again(proposal)
    elsif !attempt.last_look_could_see
      look_again(proposal)
    elsif attempt.absent_since?(CONFIRMATION_GAP)
      proposal.record_not_placed!(attempt)
    else
      attempt.absent!
      look_again(proposal)
    end
  end

  private
    # A sync that succeeded and quarantined no order: only then does "not found" mean not there.
    def whole?(run) = run.is_a?(SyncRun) && run.succeeded? && run.unmapped_values.slice(*ORDER_QUARANTINES).none?
    def look_again(proposal) = self.class.set(wait: CONFIRMATION_GAP).perform_later(proposal)
end
