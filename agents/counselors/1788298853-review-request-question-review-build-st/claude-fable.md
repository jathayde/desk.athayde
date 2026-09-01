**Bottom line**

The model is close, and the Phase 2 columns are mostly right, but four things should change before this commits: every timestamp is `timestamp without time zone` against a plan that says timestamptz, `order_proposals` overloads `stop_price` and lacks `duration`, `trades` has no one-open-trade-per-instrument constraint, and `Position` raises on a trailing stop. All four are cheap now and expensive after the migrations are history.

## Fix before commit

1. **All datetimes are naive, not timestamptz.** Plan §1 says "All timestamps timestamptz"; `db/structure.sql:40` and every other datetime column is `timestamp(6) without time zone`. Rails stores UTC so it works, but psql views, the trigger, and any raw SQL in snapshot rebuilds will disagree with the plan, and switching later is an ALTER on 22 tables, which is exactly what this step exists to prevent. Add `config/initializers/active_record.rb` with `ActiveSupport.on_load(:active_record_postgresqladapter) { self.datetime_type = :timestamptz }`, reset the database, regenerate the dump. Nothing is deployed, so amend the step 1 `users`/`sessions` migrations too rather than adding a follow-up.

2. **`order_proposals.stop_price` is two things.** `db/migrate/20260901220005_create_order_proposals.rb:15`. For a buy-stop or stop-limit entry, which is the standard breakout entry, `stop_price` is the entry trigger and there is no column for the protective stop that becomes the bracket child and `trades.planned_stop`. Add `planned_stop decimal(18,4)` and leave `stop_price` as the order's own trigger. Same table is missing `duration` and `session`: the submission payload needs DAY vs GTC and NORMAL vs SEAMLESS, and the child stop is always GTC. Add `tax_lot_method` too, since PRD §5.4 6a exposes lot selection on sell proposals. Those are the ALTERs Phase 2 would otherwise need.

3. **No uniqueness on open trades.** `db/migrate/20260901220010_create_trades.rb:28` is a plain composite index. `Journal::BootstrapJob` runs after every positions sync and `Journal::LinkFillsJob` after every transactions sync, from different tick cadences, and both create trades. Without a partial unique index the journal silently forks. This is the trades equivalent of the `trade_legs.transaction_id` index:

```sql
CREATE UNIQUE INDEX index_trades_one_open_per_instrument
  ON trades (account_id, instrument_id) WHERE status = 'open';
```

4. **`Position` crashes on trailing stops.** `app/models/order.rb:3` includes TRAILING_STOP and TRAILING_STOP_LIMIT in `STOP_TYPES`. Those orders carry a price offset and often no `stopPrice`, so `stop_price` is nil and `app/models/position.rb:17` evaluates `last_price - nil`. Guard both methods with `return if stop_price.blank?`, or define `protected?` as having a working stop order with a price. Also `protected?` at `position.rb:9` trusts the foreign key rather than the order's status, so a filled or cancelled stop reads as protection until the next orders sync clears it. Use `working_stop_order&.working?`. The nil-not-zero semantics for unprotected positions are otherwise correct and the spec pins them.

## Should fix now

5. **Append-only misses TRUNCATE.** The trigger at `db/migrate/20260901220014_create_audit_events.rb:22` is `BEFORE UPDATE OR DELETE FOR EACH ROW`; TRUNCATE does not fire row triggers. `config/ci.rb:6` runs `db:seed:replant`, which truncates every table. Harmless in test, but the same task in production wipes the audit log with no error. Add a `BEFORE TRUNCATE ... FOR EACH STATEMENT` trigger on the same function, and change the CI step to `bin/rails db:seed`, since the seeds are idempotent and replant will then fail. What remains unblockable: the app role owns the table, so `DISABLE TRIGGER` and `DROP TABLE` work. Acceptable for a single operator; a separate app role is the real fix and not worth it. Rails paths all hit the trigger correctly: `update_columns`, `delete_all`, `upsert_all`. Transactional fixture rollback does not fire triggers, which is right. `readonly? = persisted?` at `app/models/audit_event.rb:15` is the correct model-side guard. The function and trigger are in the dump and `schema_format = :sql` is set, so `db:prepare` on a fresh server installs them.

6. **`SystemSettings.instance` races.** `app/models/system_settings.rb:7` does `first || create!`; the tick job and a web request against an empty table can produce two rows. Add `t.check_constraint "id = 1"` and use `find_or_create_by!(id: 1)`. Drop `self.table_name`; Rails already infers it.

7. **`accounts.account_type` NOT NULL with no source.** Schwab's `/accounts` returns CASH or MARGIN, not taxable or ira, so `Sync::AccountsJob` will have nothing to write and the upsert fails. Make it nullable, meaning unclassified until set on the system screen, with `trading_enabled` already defaulting false. Also `accounts` is the only synced table without `raw` jsonb. `db/migrate/20260901220001_create_accounts.rb`.

8. **`db/structure.sql:4` pins Postgres 17.** `SET transaction_timeout = 0` is a PG17 setting. `db:prepare` loads the dump with `ON_ERROR_STOP`, so a PG16 dokku service fails on line four. Pin the dokku postgres image to 17 in `bin/dokku-setup`. Note `.github/workflows/ci.yml` never runs rspec or loads the schema, so only local `bin/ci` catches this.

9. **`schwab_tokens` nullability.** `db/migrate/20260901220020_create_schwab_tokens.rb`. The row only ever comes from a successful code exchange, and `TokenHealthJob` and `Sync::TickJob` compare `refresh_expires_at` directly; nil raises inside the scheduler. Make both tokens, `access_expires_at`, `refresh_expires_at`, and `issued_at` NOT NULL.

10. **Encryption.** `encrypts :access_token, :refresh_token` is right: non-deterministic, never queried by value. The spec proves ciphertext at rest in test. `filter_parameters` includes `:token`, so both columns are filtered in logs and `inspect`. What I cannot verify from here is which credentials file holds `active_record_encryption`. Rails does not merge `config/credentials.yml.enc` with `config/credentials/production.yml.enc`, so production must carry its own keys, and if the shared file's keys were copied into production, rotate them. The plan's "dev/test use their own credentials files" is not what exists; dev and test share the default file. That is fine, update the plan.

11. **Destructive `dependent` options.** `app/models/account.rb:2-8` destroys positions, orders, transactions, trades, snapshots on `account.destroy`. Accounts are never deleted; use `restrict_with_exception` like `Instrument`. `app/models/setup.rb:2` nullifies `trades.setup_id` on delete, which strips journal tags; setups have `active` for retirement, so restrict there too.

12. **Instrument identity.** Partial unique indexes on `cusip` and `schwab_instrument_id` are correct and the spec covers the many-nulls case. Gaps: no normalization, so an empty-string CUSIP passes the identity check when an instrument id is present and then collides on the partial index. Add `normalizes :cusip, with: ->(c) { c.strip.upcase.presence }`. No guard against `predecessor_instrument_id == id`. `symbol_history` writes `{symbol, until}` at `app/models/instrument.rb:15` where plan §1 says `{symbol, seen_at}`; `until` is the better shape, change the plan.

## Phase 2 ALTER check, table by table

- **orders:** nothing required. `parent_order_id`, `replaces_order_id`, `order_proposal_id`, `placed_via` cover brackets, cancel/replace, and attribution. `order_strategy_type` would be convenient for bracket sync but lives in `raw`.
- **order_proposals:** `planned_stop`, `duration`, `session`, `tax_lot_method` as above. Optional while uncommitted: `expires_at` so a Tuesday approval cannot submit on Friday. `risk_rule_version` is vestigial because `risk_rules.version` is per row; record `{rule_id, version}` pairs in `guardrail_results` and drop the column.
- **submission_attempts:** complete. `outcome` is a string, so adding `shadowed` for shadow mode is not an ALTER; add it to the enum now anyway.
- **trades / trade_legs:** the open-trade index above. Consider `trades.quantity` for the running open quantity; plan §4 recomputes it from legs, and with split ratios that fold runs on every `get_journal` call.
- **risk_rules:** complete. Warn-vs-block severity fits in `params`. Consider a partial unique index on `(rule_type, setup_id) WHERE active` so two active versions cannot coexist.
- **audit_events:** complete.

## Enums, names, and what is missing

`Trade` at `app/models/trade.rb:8-11` uses `scopes: false` plus hand-written `open`/`closed` scopes. Unnecessary: Rails' conflict check accepts `open` because Kernel defines it on Object as well as on Base, and `enum status: { open:, closed: }` is standard. Drop both. `exit` in `OrderProposal.kind` and `TradeLeg.kind` generates `exit?`, `exit!`, and a class-level `exit` scope; Rails accepts it by the same rule, and `record.exit!` shadows `Kernel#exit!` on instances only. Harmless, keep. The `Transaction` class collides with nothing at top level; `ActiveRecord::Transaction` resolves lexically inside Rails, and `belongs_to :source_transaction` at `app/models/trade_leg.rb:4` correctly dodges the `transaction` instance method. `orders.session` is not a dangerous attribute. Nothing needs renaming.

Missing for steps 3 through 6, fine to add in each step: `Instrument.resolve(cusip:, schwab_instrument_id:, symbol:, asset_type:)` implementing the §1 resolution order, `SchwabToken.current` with `access_expired?`, `refresh_expired?`, `refresh_expiring_within?`, `MarketDay.for(date)`, and the leg fold on `Trade`. Mapper note for step 3: `transactions.executed_at` is NOT NULL and Schwab's activity `time` is unverified on every type, so fall back to `tradeDate` or the whole sync raises. Nothing present is premature except `risk_rule_version`.

Small items: `spec/factories/core.rb:63` `user_audit_event` is unused and misnamed, delete it. Add one spec asserting `ActiveRecord::RecordNotUnique` on a second `trade_leg` for the same transaction, since that index is the idempotency guarantee of plan §4. Indexes `transactions (account_id, instrument_id, executed_at)` and `orders (account_id, instrument_id, status)` match the §4 and §5 iteration patterns; add only if you are regenerating anyway.
