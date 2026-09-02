# After every orders sync: the orders the app placed are linked by the broker id Schwab gave us and their
# broker outcomes recorded; the orders the operator placed by hand for shadowed proposals are matched and
# linked; a parent filled with no live child is the unprotected alert (step 4).
class Orders::ProposalLink
  def self.call(account) = new(account).call

  def initialize(account) = @account = account

  def call
    link_by_broker_id
    link_shadows
    record_outcomes
  end

  private
    def link_by_broker_id
      @account.order_proposals.where(status: %w[ submitted filled cancelled ]).where.not(broker_order_id: nil).find_each do |proposal|
        order = @account.orders.find_by(broker_order_id: proposal.broker_order_id) or next
        next if order.order_proposal_id == proposal.id
        order.update!(order_proposal: proposal, placed_via: proposal.shadow? ? :schwab_direct : :app) # a hand-placed shadow stays the operator's
      end
    end

    def link_shadows
      @account.order_proposals.awaiting_hand_placement.find_each do |proposal|
        attempt = proposal.submission_attempts.would_have_submitted.first or next
        order = Submission::Matcher.new(proposal, attempt).match or next
        order.update!(order_proposal: proposal)
        proposal.link_shadow_order!(attempt, order: order)
      end
    end

    def record_outcomes
      @account.order_proposals.submitted.where.not(broker_order_id: nil).find_each do |proposal|
        order = @account.orders.find_by(broker_order_id: proposal.broker_order_id) or next
        outcome = :filled if order.status == Schwab::Order::FILLED
        outcome = :cancelled if Schwab::Order::DEAD_STATUSES.include?(order.status)
        proposal.record_broker_outcome!(outcome) if outcome
      rescue OrderProposal::IllegalTransition => e
        Rails.error.report(e, handled: true, context: { proposal: proposal.id }) # one raced row is not the sync's problem
      end
    end
end
