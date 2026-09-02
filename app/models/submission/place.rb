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

  # A worker that wakes after the sweep already called its row unknown does not send: the reconcile job owns
  # the row now, and a second send would be the double submission this whole path exists to prevent. The check
  # is not a lock and does not need one: transaction one serialises approves (a second approve finds the row
  # not approvable), so at most one worker ever holds an attempt, and the sweep acts only after
  # STALE_SUBMITTING, longer than the client's timeouts; only a suspended process can straddle it, and the
  # late-answer transitions on the proposal cover that.
  def call
    return swept unless @proposal.reload.submitting?
    adjust_stop if @proposal.kind_exit?
    order_id = client.place_order(@account.schwab_hash, @attempt.payload)
    record { @proposal.record_submitted!(@attempt, broker_order_id: order_id) }
  rescue StopNotAdjusted => e
    record { @proposal.record_rejected!(@attempt, error: e.message) }
  rescue *MAYBE_SENT => e
    record do
      @proposal.record_unknown!(@attempt, error: "#{e.class.name.demodulize}: #{e.message}")
      Submission::ReconcileJob.set(wait: Submission::ReconcileJob::QUIET_PERIOD).perform_later(@proposal)
    end
  rescue Schwab::Error => e # a 4xx, a rate limit, an auth failure, no token: nothing was accepted
    record { @proposal.record_rejected!(@attempt, error: "#{stop_note}order not sent: #{e.message}") }
  end

  private
    def client = Schwab.client(wait: false)
    def stop_note = @proposal.child_action ? "the stop was #{@proposal.child_action_cancel_stop? ? "cancelled" : "shrunk"} first; " : ""

    def swept
      AuditEvent.log("submission_skipped", actor: :system, subject: @proposal, reason: "swept to #{@proposal.status} before the call; not sent")
      @proposal
    end

    # An answer the row can no longer take (the reconcile job already found the order, or a verdict this
    # answer cannot overturn) is kept on the record and reported, never retried and never a 500 for the operator.
    def record
      yield
    rescue OrderProposal::IllegalTransition, ActiveRecord::RecordNotUnique => e
      # RecordNotUnique: the instrument already has another unresolved submission, so a late reopen cannot take the lock.
      AuditEvent.log("submission_answer_ignored", actor: :system, subject: @proposal, reason: e.message.truncate(300), data: { status: @proposal.reload.status })
      Rails.error.report(e, handled: true, context: { proposal: @proposal.id })
      @proposal
    end

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
