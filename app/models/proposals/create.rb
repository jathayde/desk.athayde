# The one way a proposal comes into being, from the tool or the form: refuse what the halts forbid before a
# row exists, draft, save, evaluate (which engages any halt the rules ask for), and audit the creation. A
# forecast that comes with it (docs/phase-2.6-plan.md §0.2) is written in the same transaction, so a proposal
# refused for any reason leaves none. Research never decides what is proposed: a forecast's own fields are
# checked before anything else, and a forecast or a hypothesis that cannot attach is left off, on the record.
# Every refusal is an audit row.
class Proposals::Create
  class Refused < Proposals::Error; end

  def self.call(**) = new(**).call

  def initialize(forecast: nil, **arguments) # forecast: { probability:, horizon_days: }; the rest, the keywords Proposals.draft takes
    @forecast, @arguments = forecast, arguments
  end

  # Drafted outside the lock (an entry's draft reads candles from Schwab, and no lock is held across a call);
  # the checks and the write happen under the account-and-instrument lock the allocation planner takes too, so
  # a human proposal and the planner never both pass the "nothing waiting" check. The halts and the hypothesis are
  # read again under the lock, since the draft's Schwab reads take seconds.
  def call
    Forecast.check_claim!(**@forecast) if @forecast
    refuse_if_halted!
    proposal = Proposals.draft(**@arguments)
    proposal.features = Research::Features.snapshot(proposal) if proposal.kind_entry? # outside the lock: it reads SPY's history too
    OrderProposal.transaction(requires_new: true) do # a savepoint inside a caller's transaction, so a refusal here leaves the caller's usable
      OrderProposal.lock_instrument!(proposal.account, proposal.instrument)
      refuse_if_halted!(SystemSettings.instance.reload)
      open = proposal.account.order_proposals.pending.where(instrument: proposal.instrument, side: OrderProposal.sides.fetch(proposal.side)).first
      raise Refused, "#{proposal.instrument.symbol} already has a #{proposal.side} proposal waiting (##{open.id}); decide it first" if open
      unresolved = proposal.account.order_proposals.unresolved.where(instrument: proposal.instrument).first
      raise Refused, "#{proposal.instrument.symbol} has a submission pending reconciliation (##{unresolved.id}); nothing else on it until that resolves" if unresolved
      Proposals.name_hypothesis(proposal, proposal.hypothesis.reload) if proposal.hypothesis # retired while drafting: dropped, never refused
      save!(proposal)
      AuditEvent.log("proposal_created", actor: proposal.audit_actor, user: proposal.user, subject: proposal,
                     data: { kind: proposal.kind, side: proposal.side, symbol: proposal.instrument.symbol, quantity: proposal.quantity, limit_price: proposal.limit_price, stop_price: proposal.stop_price,
                             hypothesis: proposal.hypothesis_id }.compact)
      if proposal.hypothesis_note
        AuditEvent.log("hypothesis_not_named", actor: proposal.audit_actor, user: proposal.user, subject: proposal, reason: proposal.hypothesis_note)
      end
      record_forecast(proposal) if @forecast # before the evaluation, whose halts nothing after it may roll back
      proposal.evaluate!(Guardrails::Evaluator.new(proposal).call)
    end
    after_commit(proposal) { Alert.new_proposal(proposal) } unless proposal.human? # the operator made the human ones
    after_commit(proposal) { Research::SkepticJob.perform_later(proposal) } if proposal.skeptic_due?
    proposal
  rescue ActiveRecord::RecordInvalid => e
    refused(e.record.errors.full_messages.to_sentence)
  rescue Forecast::InvalidClaim => e
    refused("forecast: #{e.message}")
  rescue Refused => e
    refused(e.message)
  end

  private
    def refuse_if_halted!(settings = SystemSettings.instance)
      raise Refused, "halted: #{settings.manual_halt_reason}" if settings.manual_halt?
      raise Refused, "entries are halted by #{settings.rule_halt_rule}: #{settings.rule_halt_reason}" if OrderProposal.opens_exposure?(@arguments[:kind], @arguments[:side]) && !settings.entries_allowed?
    end

    def save!(proposal)
      proposal.save!
    rescue ActiveRecord::RecordNotUnique
      raise Refused, "#{proposal.instrument.symbol} already has a #{proposal.side} proposal waiting; decide it first" # the waiting-proposal index, raced
    end

    # Recorded outside the refused savepoint, then raised again.
    def refused(reason)
      AuditEvent.log("proposal_refused", actor: @arguments[:origin].to_s == "human" ? :human : (@arguments[:origin].to_s == "agent" ? :agent : :system), user: @arguments[:user],
                     reason: reason, data: { kind: @arguments[:kind].to_s, side: @arguments[:side].to_s, symbol: (@arguments[:instrument]&.symbol || @arguments[:symbol]).to_s.upcase })
      raise Refused, reason
    end

    # A forecast the desk cannot measure (no final close, levels the last close already settles), or one that fails
    # for any reason past its own fields, leaves the proposal without one, on the record.
    def record_forecast(proposal)
      Forecast.transaction(requires_new: true) { Forecast.record!(proposal, author: proposal.agent? ? :agent : :human, user: proposal.user, **@forecast) } # its own savepoint, so a failed insert leaves the proposal's usable
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { forecast: proposal.id }) unless e.is_a?(Forecast::Unmeasurable)
      proposal.forecast_note = e.message
      AuditEvent.log("forecast_not_recorded", actor: proposal.audit_actor, user: proposal.user, subject: proposal, reason: e.message.truncate(200), data: @forecast.transform_values(&:to_s))
    end

    # After the caller's transaction commits; a failure there never turns a created proposal into an error.
    def after_commit(proposal)
      ActiveRecord.after_all_transactions_commit do
        yield
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { proposal: proposal.id })
      end
    end
end
