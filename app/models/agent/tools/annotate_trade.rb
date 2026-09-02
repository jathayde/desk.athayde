# The write tool for the journal (PRD §5.5): appends to a trade's post-mortem, dated and marked as the agent's
# words, never replacing what the human wrote and never touching followed_setup. Interactive transport only.
class Agent::Tools::AnnotateTrade < Agent::Tool
  tool description: "Append a dated note to a trade, kept beside the human's post-mortem and never counted as it. " \
                    "Use get_journal to find the trade id.",
       input: { trade_id: { type: "integer", minimum: 1 }, note: { type: "string", minLength: 1, maxLength: 2000 } },
       required: %i[ trade_id note ],
       output: { trade_id: { type: "integer" }, agent_notes: { type: "string" } },
       read_only: false, scheduled: false

  def call(trade_id:, note:)
    trade = Trade.journaled.find_by(id: trade_id) or raise InvalidArguments, "no journaled trade #{trade_id}"
    trade.annotate!(note, actor: :agent)
    { trade_id: trade.id, agent_notes: trade.agent_notes }
  end
end
