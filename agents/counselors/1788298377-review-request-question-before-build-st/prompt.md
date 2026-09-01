# Second Opinion Request

## Question
# Review Request

## Question
Before build step 3 (the Schwab adapter) is written, produce the best-available contract for each Schwab Trader API and Market Data API call Phase 1 needs, and critique the plan's adapter design. The app has no API access yet, so the adapter will be built from community knowledge (schwab-py, schwab-api community clients, the api-evangelist OpenAPI skeletons) and every shape assumption is marked `# SCHWAB_SHAPE_UNVERIFIED` until official access arrives.

## Context

### Files to Review
- @docs/artifacts/investment-copilot-prd.md §5.1, §5.3, §7, §9
- @docs/phase-1-plan.md §0.1, §2 (jobs and the Schwab client paragraph), §12 (assumptions to verify)
- @docs/artifacts/claude-code-kickoff.md constraints: no live calls in tests, never store or log plaintext account numbers, tokens encrypted at rest, isolate every Schwab-shape assumption in the adapter layer

### Planned adapter design
`Schwab::Client` (Net::HTTP, no Faraday) with an OAuth module (authorize URL, code exchange, refresh grant), retry with exponential backoff on 429/5xx honoring Retry-After (max 3 attempts), a per-process token bucket at 120 requests/minute, request logging of method/path/status/duration only. Endpoint methods: `account_numbers`, `accounts(fields: :positions)`, `account(hash, fields:)`, `orders(hash, from:, to:, status:)`, `transactions(hash, from:, to:, types:)`, `market_hours(markets:, date:)`, `quotes(symbols)`, `price_history(symbol, period_type:, period:, frequency_type:, frequency:)`. Response mappers live beside the client and are the only code that touches Schwab field names. `Schwab::FakeClient` mirrors the interface for dev seeds and Playwright.

## Instructions
You are providing an independent review, and part of the deliverable is a reference the implementer will build from.

1. For each call above, give: HTTP method and path on `api.schwabapi.com`, required headers, query parameters with formats (date/time formats matter), and the response shape down to the field names Phase 1 needs: account hashValue and accountNumber pairing; positions with instrument cusip/symbol/assetType/instrumentId, longQuantity/shortQuantity, averagePrice, marketValue; currentBalances fields relevant to settled vs unsettled cash for a cash account; order fields (orderId, status, orderType, session, duration, orderStrategyType, childOrderStrategies, replacingOrderCollection, orderLegCollection with instruction/quantity/instrument, stopPrice, price, enteredTime, closeTime, filledQuantity); transaction/activity fields (activityId, type, subAccount, tradeDate, settlementDate, orderId, netAmount, transferItems with instrument/amount/cost/price/feeType/positionEffect); market hours (per-market sessionHours with preMarket/regularMarket/postMarket start and end, isOpen); quote fields; price history candles.
2. State the OAuth details precisely: authorize URL and parameters, token endpoint, Basic auth header construction, grant types, access token lifetime, refresh token lifetime, and whether refreshing extends the 7-day window.
3. State known limits: transactions lookback (60 days?), orders query maximum window, rate limits, symbol batch size for quotes.
4. Where sources disagree, present both readings and name the conservative one.
5. Mark anything you are not confident about as UNVERIFIED so the implementer can copy your list straight into `docs/verify-on-approval.md`.
6. Then critique the adapter design: interface shape, error taxonomy (auth failure vs rate limit vs server error vs unknown-outcome must be distinguishable by callers), what the FakeClient must be able to script for Playwright (re-auth success and failure at minimum), and how mappers should handle missing CUSIPs and unknown enum values without crashing sync.

Be direct and opinionated; do not hedge on things you know; order by importance.

## Instructions
You are providing an independent second opinion. Be critical and thorough.
- Analyze the question in the context provided
- Identify risks, tradeoffs, and blind spots
- Suggest alternatives if you see better approaches
- Be direct and opinionated — don't hedge
- Structure your response with clear headings
- Keep your response focused and actionable
