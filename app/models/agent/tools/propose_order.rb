# The write tool (PRD §5.5): creates a proposal through the same service the form uses and returns its
# evaluation. Interactive transport only, audited, never submits. An entry carries the agent's forecast
# (docs/phase-2.6-plan.md §0.2), required, and scored later on the proposal's own levels.
class Agent::Tools::ProposeOrder < Agent::Tool
  tool description: "Propose an order for the human to approve: a LIMIT buy with a stop (entry) or a LIMIT sell (exit). Rails sizes the " \
                    "entry from the max-risk rule and computes the stop collar; the guardrails run at once and the result is returned. " \
                    "Nothing is sent to Schwab; the approver decides on /proposals. Refused during a halt. quantity applies to exits only " \
                    "(it defaults to the position); entries are sized by Rails and a quantity on a buy is refused. An entry needs stop_price, " \
                    "target_price, probability, and horizon_days: your forecast that, within horizon_days sessions of the market touching " \
                    "the limit, the daily high reaches the target before the daily low reaches the stop. It is scored on the daily candles " \
                    "whatever happens to the order, so state the probability you believe, not one that argues for the trade, and do not " \
                    "restate it in the thesis: the operator forecasts blind to yours. forecast says whether it was recorded. hypothesis_id names a " \
                    "hypothesis under test that this entry is evidence for (its setup is the proposal's); only when the entry follows its rules. " \
                    "hypothesis says whether it was named.",
       input: { symbol: { type: "string", minLength: 1 }, side: { type: "string", enum: %w[ buy sell ] }, limit_price: { type: "string" },
                stop_price: { type: "string" }, target_price: { type: "string" }, probability: { type: "number", exclusiveMinimum: 0, exclusiveMaximum: 1 },
                horizon_days: { type: "integer", minimum: Forecast::HORIZON.first, maximum: Forecast::HORIZON.last },
                setup: { type: "string" }, thesis: { type: "string", minLength: 1 }, quantity: { type: "integer", minimum: 1 }, hypothesis_id: { type: "integer" } },
       required: %i[ symbol side limit_price thesis ],
       output: { proposal_id: { type: "integer" }, status: { type: "string" }, blocked: { type: "boolean" }, warnings: { type: "array", items: { type: "string" } },
                 quantity: { type: [ "integer", "null" ] }, results: { type: "object" }, forecast: { type: [ "string", "null" ] },
                 hypothesis: { type: [ "string", "null" ] } },
       read_only: false, scheduled: false

  def call(symbol:, side:, limit_price:, thesis:, stop_price: nil, target_price: nil, probability: nil, horizon_days: nil, setup: nil, quantity: nil, hypothesis_id: nil)
    entry = side == "buy"
    raise InvalidArguments, "entries are sized by Rails; do not pass a quantity on a buy" if entry && quantity
    if entry # the schema's required list cannot depend on the side
      missing = { stop_price:, target_price:, probability:, horizon_days: }.select { |_, value| value.blank? }.keys
      raise InvalidArguments, "an entry needs #{missing.to_sentence}" if missing.any?
    end
    account = Account.trading.order(:id).first or raise InvalidArguments, "no trading account"
    setup_row = setup && (Setup.find_by(name: setup) or raise InvalidArguments, "unknown setup #{setup}")
    hypothesis = hypothesis_id && (Hypothesis.find_by(id: hypothesis_id) or raise InvalidArguments, "unknown hypothesis #{hypothesis_id}")
    proposal = Proposals::Create.call(account: account, kind: entry ? :entry : :exit, side: side, symbol: symbol, limit_price: decimal(limit_price),
                                      stop_price: decimal(stop_price), target_price: entry ? decimal(target_price) : nil, setup: setup_row, thesis: thesis,
                                      origin: :agent, quantity: quantity, hypothesis: hypothesis, forecast: entry ? { probability:, horizon_days: } : nil)
    { proposal_id: proposal.id, status: proposal.status, blocked: proposal.rejected_by_rules?, warnings: proposal.warnings, quantity: proposal.quantity&.to_i, results: proposal.guardrail_results,
      forecast: entry ? (proposal.forecast_note ? "not recorded: #{proposal.forecast_note}" : "recorded") : nil,
      hypothesis: hypothesis && (proposal.hypothesis_note ? "not named: #{proposal.hypothesis_note}" : "named ##{hypothesis.id}") }
  rescue Proposals::Error, ArgumentError => e # a refusal, an unknown symbol or lot method, or a bad decimal string
    raise InvalidArguments, e.message
  end

  private
    def decimal(value) = value && BigDecimal(value.to_s)
end
