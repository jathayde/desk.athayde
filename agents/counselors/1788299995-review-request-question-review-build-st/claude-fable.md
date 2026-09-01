Review complete. Findings below, ordered by severity, with the contract checks that pass noted at the end.

## High severity

- **Concurrent 401 refresh can falsely trigger the pause path.** `app/models/schwab/client.rb:116` calls `@token.refresh!` whenever a call gets 401. Two Solid Queue jobs holding separate `SchwabToken` instances will each issue a refresh grant. If Schwab rotates refresh tokens, the second grant fails with `invalid_grant`, which raises `ReauthRequired` and pauses sync with a nag email for a token that is fine. The client cannot fix this alone. Step 4's `refresh!` must `with_lock`, reload, and return early if `access_expires_at` is already in the future. The client should also compare the bearer it sent against the current token and skip the refresh when another process already rotated it.

- **A 429 from the token endpoint becomes `ReauthRequired`.** `app/models/schwab/client.rb:97` treats every 4xx as re-auth. After the retry budget a rate-limited refresh grant pauses sync and demands re-auth. Raise `RateLimited` for 429 and reserve `ReauthRequired` for 400, 401, and 403.

- **API `RateLimited` never carries `retry_after`.** `app/models/schwab/error.rb:22` builds every subclass with the same keyword set, so the header value is dropped. The contract promises it and step 5 will reschedule on nil. Parse `Retry-After` in `for_response` and pass it through.

- **A non-JSON or empty 200 body escapes the taxonomy.** `app/models/schwab/client.rb:99` and `client.rb:107` call `JSON.parse` unguarded. Gateway HTML on a 200 and empty bodies both happen against the real API. Rescue `JSON::ParserError` into `ServerError` with the scrubbed body.

## Medium severity

- **Replacing a bracket child loses `parent_order_id`.** `app/models/schwab/order.rb:17` builds replacements with only `replaces_order_id`. A replaced stop under a bracket comes out with no parent. Pass the current `parent_order_id` into the replacement branch.

- **Activity keeps only the first security transfer item.** `app/models/schwab/activity.rb:10` uses `find`. CUSIP succession arrives as an out on A and an in on B in one activity, and step 6 needs both halves. Expose all non-fee, non-currency items alongside the primary one.

- **Leg-less container orders map to an empty instrument.** OCO and TRIGGER parents can have no `orderLegCollection`. `app/models/schwab/order.rb:15` yields an `InstrumentRef` with a nil symbol and `side` nil, and the sync will fail the NOT NULL on `orders.instrument_id`. Decide now whether containers are skipped or stored without an instrument.

- **CUSIP lookup is routed through symbol search.** `app/models/schwab/client.rb:86` sends a CUSIP as `symbol=&projection=symbol-search`. The contract lists `/instruments/{cusip}` for that case. Split into `instrument_by_symbol` and `instrument_by_cusip`.

- **Timestamp failures are not `MappingError`.** `app/models/schwab/timestamp.rb:10` raises `ArgumentError` on a malformed string and `timestamp.rb:26` raises `TypeError` on a nil candle datetime. Contract rule 8 says a per-record rescue of `MappingError` must be enough.

- **Quote batches clobber the `errors` key.** `app/models/schwab/client.rb:74` merges hashes, so invalid symbols from batch one vanish when batch two also has errors. Merge the `invalidSymbols` arrays.

- **A web request can sleep 60 seconds.** `app/models/schwab/client.rb:133` honors `Retry-After` up to the cap inside whatever thread called it. The step 8 quotes tool runs in Puma. Add a no-wait mode so web callers raise immediately and serve the cached value.

- **Transport rescue list is incomplete.** `app/models/schwab/client.rb:137` misses `EOFError`, `Net::WriteTimeout`, `Errno::ETIMEDOUT`, `Errno::EHOSTUNREACH`, `Errno::ENETUNREACH`, `Net::HTTPBadResponse`, and `IOError`. `EOFError` is the most common dropped-connection symptom with Net::HTTP.

- **Transactions makes 11 sequential calls and returns nothing on a mid-loop failure.** `app/models/schwab/client.rb:61` flattens at the end. A `RateLimited` on the seventh type discards six good responses. Let the job iterate types, or yield per type.

- **Non-trade activity quantity is dollars.** `app/models/schwab/activity.rb:21` takes `amount` from the dividend's security item, so the fixture dividend maps to a quantity of 9.6 shares. Gate quantity and price on `trade?`, or document that the job must. Side also ignores `positionEffect`, which the contract says to combine with the sign.

- **FakeClient `order` only searches the first fixture order.** `app/models/schwab/fake_client.rb:37` flattens `fixture("orders").first`, so the DEF stop and its replacement 404. Step 5's re-fetch by id will hit this.

- **FakeClient `quotes` always reports NOPE as invalid.** `app/models/schwab/fake_client.rb:47` slices the fixture's `errors` regardless of what was requested. Compute invalid as requested minus known.

## Low severity, specs, and what checks out

Low:
- **Rate budget is sound in production.** I verified Solid Cache's `increment` runs inside a transaction with a `FOR UPDATE` row lock, so the counter is shared and serialized. The only race is both processes writing the initial zero for a new minute, costing at most one count. Memory store in development is per process, which matters only with `SCHWAB_ADAPTER=http` locally.
- 4xx other than 400, 403, and 404 fall to the base `Error` at `app/models/schwab/error.rb:18`. Use a 400 to 499 range.
- A 5xx on the code exchange raises `ServerError` because `client.rb:98` hardcodes idempotent true.
- Transport backoff has no jitter, unlike the status backoff.
- `Timestamp.iso_ms` calls `utc`, which mutates a bare `Time` argument. Use `getutc`.
- `Scrub.uri` is unused. Scrubbing is key based, so an account number inside error prose would pass. Accept that.
- `shift_market_hours` keeps the `-04:00` offset on winter dates, so Playwright sessions run an hour off from December through March.
- `enqueue` is one-shot. Playwright flows that need Schwab down for a whole scenario have no sticky failure mode.
- `SCHWAB_ADAPTER=fake` in production silently serves fixtures. Raise in the initializer.
- Nested order `raw` duplicates the subtree into every parent row's jsonb.

Missing specs:
- Token endpoint 429, 5xx, and transport failure with retries on the refresh grant.
- API `RateLimited` carrying `retry_after`, which fails today.
- Non-JSON and empty 200 bodies.
- Local budget exhaustion surfacing through `Client`.
- Query params for `order`, `market_hours`, `price_history`, `instrument`, and `account`.
- Order: OCO container, replacement of a child.
- Activity: two security items, non-trade quantity.
- MarketHours: early close, missing `equity` key.
- Quote: body without a `quote` block, invalid symbols across two batches.
- PriceHistory: `empty` true, candle without `datetime`.
- FakeClient: parameter-list parity, not just method names, since `price_history(symbol, **)` passes the current check.

Isolation spec gaps at `spec/schwab_isolation_spec.rb:9`: it scans only `app/**/*.rb`, so views, `lib/`, `db/seeds.rb`, and rake tasks are unchecked. The name list will not catch the likely leak, which is a job reading `record.raw["marketValue"]`. Add `marketValue`, `averagePrice`, `netAmount`, `stopPrice`, `orderType`, `instrumentId`, `assetType`, `isOpen`, `lastPrice`, `invalidSymbols`, and `candles`.

What matches the contract: Basic auth and form encoding on the token endpoint, the `@` in the code left encoded once, `id_token` dropped, one refresh-and-retry on 401 with no loop, no retry on 4xx, the 1, 4, 16 backoff with jitter and the 60 second `Retry-After` cap, four attempts counted correctly, the idempotent split by method, scrub before any body is returned, path templates in logs, closed-day market hours, and the settled-cash derivation with both readings.
