# The real branch (docs/phase-2-plan.md §0.5, §0.6): the exit's stop action first, then the order, one call each,
# never retried; every answer Schwab can give lands as one named outcome on the proposal. A call that may have
# reached Schwab is unknown until the reconcile job says otherwise; one that certainly did not (a 4xx, an
# auth or budget refusal, a missing token) is a rejection that says the order was not sent.
class Submission::Place
  MAYBE_SENT = [ Schwab::UnknownOutcome, Schwab::ServerError, Schwab::TransportError ].freeze

  # The stop step failed or went quiet: the sell is not sent, and the operator is told what to check.
  class StopNotAdjusted < StandardError; end

  def self.call(proposal, attempt) = new(proposal, attempt).call

  def initialize(proposal, attempt)
    @proposal, @attempt = proposal, attempt
    @account = proposal.account
  end

  def call
    adjust_stop if @proposal.kind_exit?
    order_id = client.place_order(@account.schwab_hash, @attempt.payload)
    @proposal.record_submitted!(@attempt, broker_order_id: order_id)
  rescue StopNotAdjusted => e
    @proposal.record_rejected!(@attempt, error: e.message)
  rescue *MAYBE_SENT => e
    @proposal.record_unknown!(@attempt, error: "#{e.class.name.demodulize}: #{e.message}")
    Submission::ReconcileJob.set(wait: Submission::ReconcileJob::QUIET_PERIOD).perform_later(@proposal)
  rescue Schwab::Error => e # a 4xx, a rate limit, an auth failure, no token: nothing was accepted
    @proposal.record_rejected!(@attempt, error: "#{stop_note}order not sent: #{e.message}")
  rescue OrderProposal::IllegalTransition => e
    # The sweep called the row not placed before Schwab answered with an id: the id is the last fact that
    # says otherwise, so it goes on the row and the record, and the sync links the order from it.
    @proposal.update!(broker_order_id: order_id) if order_id
    AuditEvent.log("proposal_submitted", actor: :system, subject: @proposal, reason: "late answer after #{@proposal.status}", data: { broker_order_id: order_id })
    Rails.error.report(e, handled: true, context: { proposal: @proposal.id, broker_order_id: order_id })
  end

  private
    def client = Schwab.client(wait: false)
    def stop_note = @proposal.child_action ? "the stop was #{@proposal.child_action_cancel_stop? ? "cancelled" : "shrunk"} first; " : ""

    # Selling what a working stop covers: cancel the stop for a full exit, shrink it for a partial one, before
    # the sell goes in.
    def adjust_stop
      stop = @account.positions.find_by(instrument: @proposal.instrument)&.working_stop_order
      return unless stop&.working?
      remaining = stop.remaining.to_d - @proposal.quantity.to_d
      action = remaining <= 0 ? :cancel_stop : :replace_stop
      new_id = perform_stop_action(action, stop, remaining)
      @proposal.update!(child_action: action)
      AuditEvent.log("stop_adjusted", actor: :system, subject: @proposal, reason: action == :cancel_stop ? "stop cancelled" : "stop shrunk",
                     data: { stop_order: stop.broker_order_id, remaining: remaining, replacement_order: new_id })
    end

    def perform_stop_action(action, stop, remaining)
      if action == :cancel_stop
        client.cancel_order(@account.schwab_hash, stop.broker_order_id)
        nil
      else
        client.replace_order(@account.schwab_hash, stop.broker_order_id, Schwab::OrderPayload.stop(symbol: @proposal.instrument.symbol, quantity: remaining, stop_price: stop.stop_price))
      end
    rescue *MAYBE_SENT => e
      raise StopNotAdjusted, "the stop #{action == :cancel_stop ? 'cancel' : 'shrink'} got no answer (#{e.message}); check the stop at Schwab before anything else; order not sent"
    rescue Schwab::Error => e
      raise StopNotAdjusted, "the stop could not be adjusted (#{e.message}); order not sent"
    end
end
