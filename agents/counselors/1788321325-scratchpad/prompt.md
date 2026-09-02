# Review Request

## Question
Review Phase 2 step 2 of Investment Copilot (uncommitted on top of commit 28c84bf; `git status --porcelain` lists the files): the guardrail evaluator with every rule of docs/phase-2-plan.md §3, the settled-cash projection, the durable rule halts that trip, the stop-collar calculator with its quality gates, the proposal builder that freezes sizing and the collar, the hypothetical-evaluation tool, and the seeded rule set. Under 700 words.

## Files
@app/models/guardrails.rb @app/models/guardrails/context.rb @app/models/guardrails/rule.rb @app/models/guardrails/evaluator.rb @app/models/guardrails/max_risk_per_trade.rb @app/models/guardrails/max_positions.rb @app/models/guardrails/max_position_exposure.rb @app/models/guardrails/max_sector_exposure.rb @app/models/guardrails/daily_loss_halt.rb @app/models/guardrails/max_drawdown_halt.rb @app/models/guardrails/settled_cash.rb @app/models/guardrails/earnings_blackout.rb @app/models/guardrails/wash_sale.rb @app/models/guardrails/notional_cap.rb @app/models/guardrails/stop_collar.rb @app/models/guardrails/halt.rb @app/models/guardrails/pending_reconciliation.rb @app/models/stop_collar.rb @app/models/stop_collar/calculator.rb @app/models/proposals.rb @app/models/agent/tools/evaluate_hypothetical_order.rb @app/models/agent/tools/get_risk_rules.rb @app/models/order_proposal.rb @app/models/sizing.rb @db/seeds.rb
Specs: @spec/models/guardrails/evaluator_spec.rb @spec/models/stop_collar/calculator_spec.rb @spec/support/candles.rb
Design: @docs/phase-2-plan.md §0.4, §0.8 to §0.11, §3, §4; PRD §5.4 and §5.4.1 in @docs/artifacts/investment-copilot-prd.md.

## Instructions
Independent and critical. Check each rule against the PRD's wording and the plan's decisions: what a rule passes that it should not, what it counts twice or not at all (settled cash and pending buys, notional per day, positions count on a scale-in), the daily-loss and drawdown maths and their reset times, wash-sale direction and window, the collar maths (ATR form, swing buffer, floor, tight versus wide), the quality gates and the cache interaction (a stale cached history passing as fresh), what an exit proposal is judged on, and whether the evaluator can be made to write anything. Say what must change before commit versus at step 3.
