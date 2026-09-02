# The write tool (PRD §5.5): creates a proposal through the same service the form uses and returns its
# evaluation. Interactive transport only, audited, never submits.
class Agent::Tools::ProposeOrder < Agent::Tool
  tool description: "Propose an order for the human to approve: a LIMIT buy with a stop (entry) or a LIMIT sell (exit). Rails sizes the " \
                    "entry from the max-risk rule and computes the stop collar; the guardrails run at once and the result is returned. " \
                    "Nothing is sent to Schwab; the approver decides on /proposals. Refused during a halt. quantity applies to exits only " \
                    "(it defaults to the position); entries are sized by Rails and a quantity on a buy is refused.",
       input: { symbol: { type: "string", minLength: 1 }, side: { type: "string", enum: %w[ buy sell ] }, limit_price: { type: "string" },
                stop_price: { type: "string" }, setup: { type: "string" }, thesis: { type: "string", minLength: 1 }, quantity: { type: "integer", minimum: 1 } },
       required: %i[ symbol side limit_price thesis ],
       output: { proposal_id: { type: "integer" }, status: { type: "string" }, blocked: { type: "boolean" }, warnings: { type: "array", items: { type: "string" } },
                 quantity: { type: [ "integer", "null" ] }, results: { type: "object" } },
       read_only: false, scheduled: false

  def call(symbol:, side:, limit_price:, thesis:, stop_price: nil, setup: nil, quantity: nil)
    raise InvalidArguments, "entries are sized by Rails; do not pass a quantity on a buy" if side == "buy" && quantity
    account = Account.trading.order(:id).first or raise InvalidArguments, "no trading account"
    setup_row = setup && (Setup.find_by(name: setup) or raise InvalidArguments, "unknown setup #{setup}")
    proposal = Proposals::Create.call(account: account, kind: side == "buy" ? :entry : :exit, side: side, symbol: symbol, limit_price: BigDecimal(limit_price.to_s),
                                      stop_price: stop_price && BigDecimal(stop_price.to_s), setup: setup_row, thesis: thesis, origin: :agent, quantity: quantity)
    { proposal_id: proposal.id, status: proposal.status, blocked: proposal.rejected_by_rules?, warnings: proposal.warnings, quantity: proposal.quantity&.to_i, results: proposal.guardrail_results }
  rescue Proposals::Error, ArgumentError => e # a refusal, an unknown symbol, or a bad decimal string
    raise InvalidArguments, e.message
  end
end
