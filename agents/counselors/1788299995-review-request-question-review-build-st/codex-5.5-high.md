**Findings**

1. **Production token flow is not implemented.**  
[app/models/schwab.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab.rb:10) calls `SchwabToken.current`, but [app/models/schwab_token.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab_token.rb:1) defines no `current`. The 401 path in [client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:116) also expects `refresh!`, which does not exist. In production, `Schwab.client` will fail before the first request, and expired-token recovery will not work.

2. **Concurrent 401s can double-refresh the same token.**  
[client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:116) directly calls `@token.refresh!` with no visible row lock, compare-and-swap, or reload guard. Under Solid Queue/Puma concurrency, multiple jobs can observe the same expired token and refresh simultaneously. The contract explicitly calls out avoiding double-refresh.

3. **Transaction polling omits contract transaction types.**  
[client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:15) leaves out `MEMORANDUM`, `MARGIN_CALL`, `MONEY_MARKET`, and `SMA_ADJUSTMENT`. The contract lists them as valid `types`, and some are relevant to cash movement/corporate-action visibility. This will silently miss real account activity.

4. **CUSIP instrument lookup endpoint is missing.**  
[client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:86) always calls `/instruments?symbol=...&projection=symbol-search`. The contract also requires `GET /marketdata/v1/instruments/{cusip}`. A caller passing a CUSIP to `instrument(symbol_or_cusip)` may not get the intended lookup.

5. **HTTP 429 errors lose `retry_after`.**  
[error.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/error.rb:17) creates `RateLimited`, but [error.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/error.rb:22) never passes `retry_after`. After retry exhaustion, callers cannot know Schwab’s retry delay.

6. **Transport retries do not use jitter.**  
Response retries use jitter in [client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:152), but transport retries sleep exact `[1, 4, 16]` at [client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:140). That violates the contract and can synchronize workers during an outage.

7. **Non-JSON error bodies are not scrubbed.**  
[Scrub.body](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/scrub.rb:16) returns non-JSON unchanged, and error messages summarize that body. Gateway 401/5xx bodies are allowed to be non-JSON by the contract, so any account number or sensitive text in those bodies can leak into `Schwab::Error#body` and exception messages.

8. **Quote chunking loses invalid-symbol errors from earlier chunks.**  
[client.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/client.rb:73) merges raw chunk hashes. If multiple chunks contain top-level `"errors"`, later chunks overwrite earlier invalid symbols before [quote.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/quote.rb:6) sees them.

9. **Nested replacement lineage is incomplete.**  
[order.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/order.rb:17) sets `replaces_order_id` on replacements but does not preserve an existing `parent_order_id`. A replacement nested under a bracket child loses its parent lineage.

10. **Activity side derivation ignores `positionEffect`.**  
[activity.rb](/Users/jathayde/Development/Personal/desk.athayde/app/models/schwab/activity.rb:31) derives side only from `netAmount`. The contract says side comes from `positionEffect` plus `netAmount`; this will misclassify edge cases such as zero-net trades and some opening/closing flows.

**Spec Gaps**

Client specs do not cover `account` query params, `order(hash, order_id)`, `market_hours`, `price_history`, or the CUSIP instrument endpoint. There is also no concurrency spec for token refresh, no Solid Cache-backed rate-budget spec, and no multi-chunk quote invalid-symbol spec.

I could not run the suite because the local Bundler version required by `Gemfile.lock` is not installed, and the workspace is read-only.
