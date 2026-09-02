class Agent::Tools::EvaluateHypotheticalOrder < Agent::Tool
  tool description: "Dry-run the guardrails over an order that is not created: sizing, the stop collar, and every rule's outcome " \
                    "(pass, caution, block, unavailable, skipped). Nothing is written and no halt is engaged. Entries are LIMIT buys " \
                    "with a stop; exits are LIMIT sells of the held quantity unless a quantity is given.",
       input: { symbol: { type: "string", minLength: 1 }, side: { type: "string", enum: %w[ buy sell ] }, limit_price: { type: "string" },
                stop_price: { type: "string" }, setup: { type: "string" }, quantity: { type: "integer", minimum: 1 } },
       required: %i[ symbol side limit_price ],
       output: { blocked: { type: "boolean" }, warnings: { type: "array", items: { type: "string" } }, needs_override: { type: "boolean" },
                 would_trip_halt: { type: "array", items: { type: "string" } }, quantity: { type: [ "integer", "null" ] }, sizing: { type: "object" },
                 collar: { type: "object" }, results: { type: "object" } }

  def call(symbol:, side:, limit_price:, stop_price: nil, setup: nil, quantity: nil)
    account = Account.trading.order(:id).first or raise InvalidArguments, "no trading account"
    setup_row = setup && (Setup.find_by(name: setup) or raise InvalidArguments, "unknown setup #{setup}")
    proposal = Proposals.draft(account: account, kind: side == "buy" ? :entry : :exit, side: side, symbol: symbol, limit_price: BigDecimal(limit_price.to_s),
                               stop_price: stop_price && BigDecimal(stop_price.to_s), setup: setup_row, origin: :agent, quantity: quantity)
    report = Guardrails::Evaluator.new(proposal).call
    { blocked: report.blocked?, warnings: report.warnings, needs_override: report.needs_override?, would_trip_halt: report.trips.map { |t| t[:rule] },
      quantity: proposal.quantity&.to_i, sizing: proposal.sizing, collar: proposal.collar, results: report.to_h }
  rescue ArgumentError => e # a bad decimal string
    raise InvalidArguments, e.message
  end
end
