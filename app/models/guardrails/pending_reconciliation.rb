# Built in: while a submission on this instrument is unresolved, nothing else on it may be approved.
class Guardrails::PendingReconciliation < Guardrails::Rule
  def evaluate
    locked = OrderProposal.unresolved.where(instrument: proposal.instrument).where.not(id: proposal.id).exists?
    locked ? block(reason: "a submission on #{proposal.instrument.symbol} is still unresolved") : pass
  end
end
