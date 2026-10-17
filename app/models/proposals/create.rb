# The one way a proposal comes into being, from the tool or the form: refuse what the halts forbid before a
# row exists, draft, save, evaluate (which engages any halt the rules ask for), and audit the creation. A
# forecast that comes with it (docs/phase-2.6-plan.md §0.2) is written in the same transaction, so a proposal
# refused for any reason leaves none.
class Proposals::Create
  class Refused < Proposals::Error; end

  def self.call(**) = new(**).call

  def initialize(forecast: nil, **arguments) # forecast: { probability:, horizon_days: }; the rest, the keywords Proposals.draft takes
    @forecast, @arguments = forecast, arguments
  end

  # Drafted outside the lock (an entry's draft reads candles from Schwab, and no lock is held across a call);
  # the checks and the write happen under the account-and-instrument lock the allocation planner takes too, so
  # a human proposal and the planner never both pass the "nothing waiting" check.
  def call
    settings = SystemSettings.instance
    raise Refused, "halted: #{settings.manual_halt_reason}" if settings.manual_halt?
    raise Refused, "entries are halted by #{settings.rule_halt_rule}: #{settings.rule_halt_reason}" if OrderProposal.opens_exposure?(@arguments[:kind], @arguments[:side]) && !settings.entries_allowed?
    proposal = Proposals.draft(**@arguments)
    proposal.features = Research::Features.snapshot(proposal) if proposal.kind_entry? # outside the lock: it reads SPY's history too
    OrderProposal.transaction(requires_new: true) do # a savepoint inside a caller's transaction, so a refusal here leaves the caller's usable
      OrderProposal.lock_instrument!(proposal.account, proposal.instrument)
      open = proposal.account.order_proposals.pending.where(instrument: proposal.instrument, side: OrderProposal.sides.fetch(proposal.side)).first
      raise Refused, "#{proposal.instrument.symbol} already has a #{proposal.side} proposal waiting (##{open.id}); decide it first" if open
      unresolved = proposal.account.order_proposals.unresolved.where(instrument: proposal.instrument).first
      raise Refused, "#{proposal.instrument.symbol} has a submission pending reconciliation (##{unresolved.id}); nothing else on it until that resolves" if unresolved
      proposal.save!
      AuditEvent.log("proposal_created", actor: proposal.audit_actor, user: proposal.user, subject: proposal,
                     data: { kind: proposal.kind, side: proposal.side, symbol: proposal.instrument.symbol, quantity: proposal.quantity, limit_price: proposal.limit_price, stop_price: proposal.stop_price,
                             hypothesis: proposal.hypothesis_id }.compact)
      if proposal.hypothesis_note
        AuditEvent.log("hypothesis_not_named", actor: proposal.audit_actor, user: proposal.user, subject: proposal, reason: proposal.hypothesis_note)
      end
      record_forecast(proposal) if @forecast # before the evaluation, whose halts a refusal here must not roll back
      proposal.evaluate!(Guardrails::Evaluator.new(proposal).call)
    end
    ActiveRecord.after_all_transactions_commit { Alert.new_proposal(proposal) } unless proposal.human? # the operator made the human ones
    ActiveRecord.after_all_transactions_commit { Research::SkepticJob.perform_later(proposal) } if proposal.skeptic_due?
    proposal
  rescue ActiveRecord::RecordNotUnique
    raise Refused, "#{proposal.instrument.symbol} already has a #{proposal.side} proposal waiting; decide it first" # only the save can collide, after the draft
  rescue ActiveRecord::RecordInvalid => e
    raise Refused, e.record.errors.full_messages.to_sentence
  end

  private
    # A forecast the author got wrong refuses the proposal; one the desk cannot measure (no final close, levels the
    # last close already settles) leaves the proposal without one, on the record, so a forecast never decides what
    # is proposed.
    def record_forecast(proposal)
      Forecast.record!(proposal, author: proposal.agent? ? :agent : :human, user: proposal.user, **@forecast)
    rescue Forecast::Unmeasurable => e
      proposal.forecast_note = e.message
      AuditEvent.log("forecast_not_recorded", actor: proposal.audit_actor, user: proposal.user, subject: proposal, reason: e.message, data: @forecast.transform_values(&:to_s))
    rescue ArgumentError => e
      raise Refused, "forecast: #{e.message}"
    end
end
