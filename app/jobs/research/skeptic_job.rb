module Research
  # The case against an entry (docs/phase-2.6-plan.md §0.9): after the proposal commits, one agent run over the
  # read-only tools, its note frozen on the proposal. Never for an entry the rules rejected (nothing to decide),
  # never past the day's cap, never emailed; a run that ended without a note is a line on the proposal page. A run
  # that finished but whose note was never written (a worker killed between the two) is written from, not paid for
  # again. Reads; writes the run, the note, and its audit.
  class SkepticJob < ApplicationJob
    DAILY_CAP = 25

    limits_concurrency to: 1, key: ->(proposal) { "skeptic-#{proposal.id}" }, on_conflict: :discard

    def perform(proposal)
      return unless proposal.skeptic_due?
      AgentRun.sweep_stale!
      run = proposal.skeptic_runs.where.not(status: :failed).first || start(proposal) or return
      Agent::Conversation.new(run).perform if run.running?
      proposal.record_skeptic_note!(run.reload) if run.succeeded?
    rescue ActiveRecord::RecordNotUnique
      nil # another worker started this proposal's run
    end

    private
      def start(proposal)
        attributes = { kind: :skeptic, order_proposal: proposal, market_date: MarketDay.today, started_at: Time.current }
        if AgentRun.skeptic.where(market_date: MarketDay.today).where.not(status: :skipped).count >= DAILY_CAP
          return AgentRun.create!(**attributes, status: :skipped, finished_at: Time.current, error: "the day's #{DAILY_CAP} skeptic notes are spent") && nil
        end
        AgentRun.create!(**attributes, status: :running)
      end
  end
end
