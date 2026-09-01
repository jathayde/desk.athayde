**Findings**

1. **High: Timestamps violate the plan globally.**  
   The plan says “All timestamps `timestamptz`” in [docs/phase-1-plan.md](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md:24), but `structure.sql` shows `timestamp without time zone` throughout, e.g. [db/structure.sql](/Users/jathayde/Development/Personal/desk.athayde/db/structure.sql:40). This affects token expiry, market-session boundaries, order reconciliation windows, audit ordering, and snapshot rebuilds. Fix this before these migrations become committed history.

2. **High: Instrument fallback identity is blocked by the model.**  
   Plan §1 requires identity resolution by CUSIP, then Schwab instrument id, then `symbol + asset_type` with a `needs_review` audit. The migration supports nullable CUSIP/id, but [app/models/instrument.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/instrument.rb:19) rejects records with neither CUSIP nor Schwab id. That makes the planned last-resort sync path impossible. Also `symbol_history` is shaped as `{symbol, until}` in [app/models/instrument.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/instrument.rb:15), not the planned `[{symbol, seen_at}]`.

3. **High: Phase 2 order proposals will likely need ALTERs.**  
   `orders` has `duration`, `session`, and `tax_lot_method`, but `order_proposals` does not: see [db/migrate/20260901220005_create_order_proposals.rb](/Users/jathayde/Development/Personal/desk.athayde/db/migrate/20260901220005_create_order_proposals.rb:8). Phase 2 approval needs to show and submit the exact Schwab order spec, not infer hidden defaults. I would add `duration`, `session`, and `tax_lot_method` to `order_proposals` now, or replace the scalar order-spec columns with a versioned `order_spec` JSONB. For bracket stops, consider explicit child-stop spec fields if parent and stop can differ.

4. **High: Historical/idempotency data can be erased through Active Record dependencies.**  
   [app/models/account.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/account.rb:2) uses `dependent: :destroy` for positions, balances, orders, transactions, trades, snapshots, and proposals. [app/models/order_proposal.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/order_proposal.rb:7) can nullify orders and destroy submission attempts. That is wrong for broker history, journal history, and duplicate-submission forensics. Prefer `restrict_with_exception` for accounts/proposals once rows have historical meaning.

5. **High: `trades` needs an open-trade uniqueness guard.**  
   The journal builder is zero-to-zero, one open lifecycle per account/instrument. Current schema only has a non-unique index on `[account_id, instrument_id, status]` in [db/migrate/20260901220010_create_trades.rb](/Users/jathayde/Development/Personal/desk.athayde/db/migrate/20260901220010_create_trades.rb:28). Concurrent bootstrap/link jobs can create duplicate open trades. Add a partial unique index on `(account_id, instrument_id)` where `status = 'open'`.

6. **Medium: Stop/risk semantics are too trusting.**  
   `Position#protected?` only checks presence of `working_stop_order` in [app/models/position.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/position.rb:9). It does not verify same account/instrument, sell side, working status, stop type, or a present `stop_price`. `distance_to_stop` and `open_risk` can crash or misstate risk if `stop_price` is nil. Also [app/models/order.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/order.rb:3) includes trailing stop types, but the plan only defines STOP/STOP_LIMIT math.

7. **Medium: Synthetic bootstrap legs are forced to lie about time.**  
   `trade_legs.executed_at` is `null: false` in [db/migrate/20260901220011_create_trade_legs.rb](/Users/jathayde/Development/Personal/desk.athayde/db/migrate/20260901220011_create_trade_legs.rb:11). Bootstrap legs explicitly have no source transaction and unknown entry history. Either make `executed_at` nullable or add a separate `synthetic`/`observed_at` shape so Step 6 does not invent execution times.

8. **Medium: Audit append-only is good, but incomplete against TRUNCATE/admin paths.**  
   The DB trigger exists in [db/migrate/20260901220014_create_audit_events.rb](/Users/jathayde/Development/Personal/desk.athayde/db/migrate/20260901220014_create_audit_events.rb:22), the SQL dump preserves it, and the model refuses persisted updates via [app/models/audit_event.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/audit_event.rb:15). Normal Rails update/delete paths are covered. `TRUNCATE audit_events`, disabled triggers, table-owner DDL, and destructive schema loads still bypass the guarantee. Add a `BEFORE TRUNCATE` trigger if this is meant to resist Rails console/operator mistakes.

9. **Medium: Enum naming mostly survives, but `exit` should be prefixed.**  
   `Trade` avoids the `open` enum scope collision with `scopes: false` and explicit scopes in [app/models/trade.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/trade.rb:8). `Transaction` as a class name is acceptable, and `TradeLeg` wisely avoids a `transaction` association name. But `exit` enum values in [app/models/order_proposal.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/order_proposal.rb:11) and [app/models/trade_leg.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/trade_leg.rb:6) create awkward `exit`, `exit?`, and `exit!` APIs. Use enum prefixes or rename to `closing`.

**Schwab Token**

`SchwabToken` correctly uses Active Record Encryption for `access_token` and `refresh_token` in [app/models/schwab_token.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab_token.rb:2). I cannot verify encrypted credentials from source, but the declaration is right and nondeterministic encryption is fine because tokens are not queried. Missing for Step 3: singleton/current-token access, refresh-expiry methods, 25-minute refresh decision, “refresh expiry never moves” enforcement, and failure/pause helpers.

**Missing Model Surface For Steps 3-6**

Add these soon, either on models or service objects with small model helpers: `Instrument.resolve_from_schwab!`, `Order#working_stop_candidate?`, replacement-chain traversal, `Trade.open_for`, current quantity from legs, bootstrap creation, fill application, review completion/R recompute, and snapshot rebuild math entry points.

I did not run specs because this review was performed in a read-only sandbox.
