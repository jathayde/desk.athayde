# The one way a proposal comes into being, from the tool or the form: refuse what the halts forbid before a
# row exists, draft, save, evaluate (which engages any halt the rules ask for), and audit the creation.
class Proposals::Create
  class Refused < Proposals::Error; end

  def self.call(**) = new(**).call

  def initialize(**arguments) = @arguments = arguments # the keywords Proposals.draft takes

  # Drafted outside the lock (an entry's draft reads candles from Schwab, and no lock is held across a call);
  # the checks and the write happen under the account-and-instrument lock the allocation planner takes too, so
  # a human proposal and the planner never both pass the "nothing waiting" check.
  def call
    settings = SystemSettings.instance
    raise Refused, "halted: #{settings.manual_halt_reason}" if settings.manual_halt?
    raise Refused, "entries are halted by #{settings.rule_halt_rule}: #{settings.rule_halt_reason}" if OrderProposal.opens_exposure?(@arguments[:kind], @arguments[:side]) && !settings.entries_allowed?
    proposal = Proposals.draft(**@arguments)
    OrderProposal.transaction(requires_new: true) do # a savepoint inside a caller's transaction, so a refusal here leaves the caller's usable
      OrderProposal.lock_instrument!(proposal.account, proposal.instrument)
      open = proposal.account.order_proposals.pending.where(instrument: proposal.instrument, side: OrderProposal.sides.fetch(proposal.side)).first
      raise Refused, "#{proposal.instrument.symbol} already has a #{proposal.side} proposal waiting (##{open.id}); decide it first" if open
      unresolved = proposal.account.order_proposals.unresolved.where(instrument: proposal.instrument).first
      raise Refused, "#{proposal.instrument.symbol} has a submission pending reconciliation (##{unresolved.id}); nothing else on it until that resolves" if unresolved
      proposal.save!
      AuditEvent.log("proposal_created", actor: proposal.audit_actor, user: proposal.user, subject: proposal,
                     data: { kind: proposal.kind, side: proposal.side, symbol: proposal.instrument.symbol, quantity: proposal.quantity, limit_price: proposal.limit_price, stop_price: proposal.stop_price })
      proposal.evaluate!(Guardrails::Evaluator.new(proposal).call)
    end
    ActiveRecord.after_all_transactions_commit { Alert.new_proposal(proposal) } unless proposal.human? # the operator made the human ones
    proposal
  rescue ActiveRecord::RecordNotUnique
    raise Refused, "#{proposal.instrument.symbol} already has a #{proposal.side} proposal waiting; decide it first" # only the save can collide, after the draft
  rescue ActiveRecord::RecordInvalid => e
    raise Refused, e.record.errors.full_messages.to_sentence
  end
end
