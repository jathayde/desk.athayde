# Finds the broker order a submission produced when Schwab never told us its id: an ambiguous real submission
# (step 4) or a shadowed one the operator placed by hand. Conservative by design: unlinked orders only, alive
# or filled, the same instrument, side, quantity, type, price, and shape (a bracket parent for an entry, a
# single for an exit), entered inside the attempt's window; two matches are ambiguous for the operator, never
# "found".
class Submission::Matcher
  PRICE_TOLERANCE = BigDecimal("0.01")
  SHADOW_WINDOW = 3.days

  def initialize(proposal, attempt, window: SHADOW_WINDOW)
    @proposal, @attempt, @window = proposal, attempt, window
  end

  def candidates
    @candidates ||= find_candidates
  end

  # Exactly one, or nothing: the caller decides what "two" means.
  def match = candidates.one? ? candidates.first : nil
  def ambiguous? = candidates.many?

  private
    def find_candidates
      window = @attempt.attempted_at - 5.minutes..@attempt.attempted_at + @window
    scope = @proposal.account.orders.where(order_proposal_id: nil, parent_order_id: nil, instrument: @proposal.instrument, side: OrderProposal.sides.fetch(@proposal.side),
                                           order_type: @proposal.order_type, entered_at: window).where.not(status: Schwab::Order::DEAD_STATUSES + [ Schwab::Order::GONE ])
    scope.includes(:child_orders).select { |o| o.quantity.to_d == @proposal.quantity.to_d && (o.limit_price.to_d - @proposal.limit_price.to_d).abs <= PRICE_TOLERANCE && shape_matches?(o) }
  end

    def shape_matches?(order) = @proposal.kind_entry? ? order.child_orders.any? : order.child_orders.none?
end
