**Bottom Line**

The planned adapter is directionally right, but two changes are mandatory before build step 3: do not log raw request paths because account hashes appear in paths, and do not rely on a per-process rate limiter as the only throttle if web and worker processes can both call Schwab.

Everything below should be treated as the initial contract. Fields marked `# SCHWAB_SHAPE_UNVERIFIED` belong in `docs/verify-on-approval.md`.

**Sources Used**

Reviewed local files: [investment-copilot-prd.md](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/investment-copilot-prd.md), [phase-1-plan.md](/Users/jathayde/Development/Personal/desk.athayde/docs/phase-1-plan.md), [claude-code-kickoff.md](/Users/jathayde/Development/Personal/desk.athayde/docs/artifacts/claude-code-kickoff.md).

External references: schwab-py client/auth docs and source, api-evangelist OpenAPI skeletons, and typed Rust client docs. schwab-py confirms account hashes, endpoint paths, date formatting, order/transaction limits, and token endpoints. ([schwab-py.readthedocs.io](https://schwab-py.readthedocs.io/en/latest/client.html)) ([raw.githubusercontent.com](https://raw.githubusercontent.com/alexgolec/schwab-py/main/schwab/client/base.py)) ([raw.githubusercontent.com](https://raw.githubusercontent.com/alexgolec/schwab-py/main/schwab/auth.py)) The OpenAPI skeletons are useful for names but have obvious base-url mistakes for Trader endpoints, so treat them as scaffolding only. ([raw.githubusercontent.com](https://raw.githubusercontent.com/api-evangelist/charles-schwab/refs/heads/main/openapi/charles-schwab-accounts-api-openapi.yml)) ([raw.githubusercontent.com](https://raw.githubusercontent.com/api-evangelist/charles-schwab/refs/heads/main/openapi/charles-schwab-orders-api-openapi.yml))

**OAuth Contract**

Authorize URL: `GET https://api.schwabapi.com/v1/oauth/authorize`. Params: `response_type=code`, `client_id=<app_key>`, `redirect_uri=<exact registered callback>`, `state=<csrf token>`. `scope` is omitted unless Schwab portal docs after approval require it. `# SCHWAB_SHAPE_UNVERIFIED: scope parameter and accepted scope names`.

Token URL: `POST https://api.schwabapi.com/v1/oauth/token`. Headers: `Authorization: Basic <base64(app_key + ":" + app_secret)>`, `Content-Type: application/x-www-form-urlencoded`, `Accept: application/json`. Code exchange body: `grant_type=authorization_code&code=<code>&redirect_uri=<exact callback>`. Refresh body: `grant_type=refresh_token&refresh_token=<refresh_token>`. schwab-py uses the same token endpoint and HTTP basic client auth. ([raw.githubusercontent.com](https://raw.githubusercontent.com/alexgolec/schwab-py/main/schwab/auth.py))

Lifetimes: access token is 30 minutes; refresh token is 7 days. Refreshing access tokens should be treated as not extending the refresh-token window. This is consistent with the PRD and community clients, but verify once official portal access is granted. ([docs.rs](https://docs.rs/schwab-sdk?utm_source=openai)) `# SCHWAB_SHAPE_UNVERIFIED: refresh grant does not extend 7-day refresh-token expiry`.

**Common Request Rules**

All Trader and Market Data API calls: host `https://api.schwabapi.com`, header `Authorization: Bearer <access_token>`, `Accept: application/json`. `Content-Type` only when sending a body. Do not log headers, bodies, tokens, query values, raw account numbers, or account hashes.

Date formats: `fromEnteredTime`, `toEnteredTime`, `startDate`, `endDate` should be UTC ISO strings formatted `YYYY-MM-DDTHH:MM:SSZ`; schwab-py formats this way. `pricehistory` `startDate`/`endDate` are epoch milliseconds. `market_hours date` is `YYYY-MM-DD`. ([raw.githubusercontent.com](https://raw.githubusercontent.com/alexgolec/schwab-py/main/schwab/client/base.py)) ([raw.githubusercontent.com](https://raw.githubusercontent.com/alexgolec/schwab-py/main/schwab/client/base.py))

**Endpoint Contracts**

`account_numbers`: `GET /trader/v1/accounts/accountNumbers`. Response: array of `{ accountNumber, hashValue }`. Source disagreement: schwab-py describes mapping raw account number to hash; api-evangelist describes encrypted identifiers. Conservative implementation: treat `accountNumber` as plaintext-sensitive, encrypt or discard immediately, and use only `hashValue` for later paths. ([schwab-py.readthedocs.io](https://schwab-py.readthedocs.io/en/latest/client.html)) ([raw.githubusercontent.com](https://raw.githubusercontent.com/api-evangelist/charles-schwab/refs/heads/main/openapi/charles-schwab-accounts-api-openapi.yml))

`accounts(fields: :positions)`: `GET /trader/v1/accounts?fields=positions`. Response is likely array of wrappers `{ securitiesAccount: { accountNumber, type, roundTrips, isDayTrader, isClosingOnlyRestricted, positions, currentBalances, initialBalances, projectedBalances } }`. schwab-py notes linked account calls do not return account hashes, so join through `/accounts/accountNumbers`. ([schwab-py.readthedocs.io](https://schwab-py.readthedocs.io/en/latest/client.html)) `# SCHWAB_SHAPE_UNVERIFIED: exact account wrapper nesting and absence of hashValue`.

`account(hash, fields:)`: `GET /trader/v1/accounts/{hashValue}?fields=positions`. Same account shape as above.

Positions under `securitiesAccount.positions[]`: use `instrument.{cusip,symbol,assetType,instrumentId,description}`, `longQuantity`, `shortQuantity`, `averagePrice`, `marketValue`; also persist raw. Typed community models include additional quantity and P/L fields, so mapper should ignore extras. ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.Position.html)) `# SCHWAB_SHAPE_UNVERIFIED: instrumentId presence for every asset type`.

Cash balances under `currentBalances`: Phase 1 needs `cashAvailableForTrading`, `cashAvailableForWithdrawal`, `cashBalance`, `totalCash`, `unsettledCash`, and probably `longNonMarginableMarketValue`. For equity use `liquidationValue` if present, else cash plus position market value. `settled_cash` should not be derived casually; conservative v1 mapping is `cashAvailableForTrading` as spendable cash, `unsettledCash` as separate warning field. ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.CashBalance.html)) `# SCHWAB_SHAPE_UNVERIFIED: exact settled-cash source field for cash accounts`.

`orders`: `GET /trader/v1/accounts/{hashValue}/orders?fromEnteredTime=<UTC ISO>&toEnteredTime=<UTC ISO>&status=<enum>&maxResults=<int>`. Response: array of orders with `orderId`, `status`, `orderType`, `session`, `duration`, `orderStrategyType`, `childOrderStrategies[]`, `replacingOrderCollection[]`, `orderLegCollection[]`, `stopPrice`, `price`, `enteredTime`, `closeTime`, `filledQuantity`, `remainingQuantity`, `cancelable`, `editable`, `statusDescription`. Order legs: `instruction`, `quantity`, `instrument.{symbol,cusip,assetType,instrumentId}`. The Rust model confirms recursive child/replacement orders and these core fields. ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.Order.html))

`transactions`: `GET /trader/v1/accounts/{hashValue}/transactions?startDate=<UTC ISO>&endDate=<UTC ISO>&types=<types>&symbol=<optional>`. Response: array with `activityId`, `type`, `activityType`, `status`, `subAccount`, `tradeDate`, `settlementDate`, `time`, `orderId`, `positionId`, `netAmount`, `description`, `transferItems[]`. Transfer item: `instrument`, `amount`, `cost`, `price`, `feeType`, `positionEffect`. ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.Transaction.html)) ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.TransferItem.html)) Source disagreement: schwab-py comma-joins `types`; another community report says repeated `types` params may be the intended shape. Conservative adapter API accepts an array and centralizes encoding behind one method. `# SCHWAB_SHAPE_UNVERIFIED: comma vs repeated types query encoding`.

`market_hours`: `GET /marketdata/v1/markets?markets=equity,option&date=YYYY-MM-DD`. Response likely keyed by market/product, containing `date`, `marketType`, `exchange`, `category`, `product`, `productName`, `isOpen`, `sessionHours.{preMarket,regularMarket,postMarket}[]` with `{ start, end }` ISO timestamps. ([raw.githubusercontent.com](https://raw.githubusercontent.com/api-evangelist/charles-schwab/refs/heads/main/openapi/charles-schwab-market-hours-api-openapi.yml)) ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.Hours.html)) `# SCHWAB_SHAPE_UNVERIFIED: exact nesting keys such as equity/EQ and exact session key casing`.

`quotes`: `GET /marketdata/v1/quotes?symbols=AAPL,MSFT&fields=quote,reference,regular,extended&indicative=false`. Response: object keyed by symbol. For equities, map `symbol`, `assetMainType`, `assetSubType`, `quoteType`, `realtime`, `ssid`, `reference.{cusip,description,exchange,exchangeName}`, `quote.{bidPrice,askPrice,lastPrice,openPrice,highPrice,lowPrice,closePrice,totalVolume,quoteTime,tradeTime,mark,netChange,netPercentChange}`. ([raw.githubusercontent.com](https://raw.githubusercontent.com/api-evangelist/charles-schwab/refs/heads/main/openapi/charles-schwab-quotes-api-openapi.yml)) ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.EquityResponse.html)) ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.EquityQuote.html))

`price_history`: `GET /marketdata/v1/pricehistory?symbol=AAPL&periodType=year&period=1&frequencyType=daily&frequency=1&startDate=<epoch_ms>&endDate=<epoch_ms>&needExtendedHoursData=true&needPreviousClose=true`. Response: `{ symbol, empty, candles:[{ datetime, open, high, low, close, volume }], previousClose, previousCloseDate, previousCloseDateISO8601 }`. ([raw.githubusercontent.com](https://raw.githubusercontent.com/api-evangelist/charles-schwab/refs/heads/main/openapi/charles-schwab-price-history-api-openapi.yml)) ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.CandleList.html)) ([docs.rs](https://docs.rs/schwab/latest/schwab/struct.Candle.html))

**Known Limits**

Orders: `fromEnteredTime` must be within 60 days and `toEnteredTime` must be set with it. ([schwab-py.readthedocs.io](https://schwab-py.readthedocs.io/en/latest/client.html)) Transactions: `startDate` must be within 60 days; default is 60 days back. ([schwab-py.readthedocs.io](https://schwab-py.readthedocs.io/en/latest/client.html)) Price history: minute data appears capped around 48 days; 5/10/15/30-minute data around 9 months; daily/weekly lookback is unclear. ([schwab-py.readthedocs.io](https://schwab-py.readthedocs.io/en/latest/client.html))

Rate limit: `120 requests/minute` is not verified. Use it only as a starting cap. `# SCHWAB_SHAPE_UNVERIFIED: official Trader and Market Data rate limits`. Quote batch size is also unverified; start with a configurable conservative chunk size, e.g. 100 symbols, and lower it on 400/414/429. `# SCHWAB_SHAPE_UNVERIFIED: maximum symbols per /quotes request`.

**Adapter Critique**

The interface is mostly right, but `accounts(fields: :positions)` should accept `fields: [:positions]` and normalize to Schwab’s comma string internally. That keeps room for future fields without changing callers.

The logging plan is unsafe as written. `method/path/status/duration` still logs `/accounts/{hashValue}`. Log route templates like `/trader/v1/accounts/:hash/orders`, plus a local account id or short irreversible fingerprint if needed.

The per-process token bucket is inadequate once Rails has both web and worker processes. Use a shared limiter through Postgres/Solid Cache, or set a much lower per-process cap and accept underutilization. Reads from MCP and sync jobs must share one budget.

Define error classes now: `Schwab::AuthError`, `TokenExpired`, `PermissionDenied`, `RateLimited(retry_after:)`, `ServerError(retriable:)`, `NetworkError`, `TimeoutError`, `ShapeError`, `UnknownOutcome`. `UnknownOutcome` matters for Phase 2 order submission; do not blur it into retryable server failure.

`FakeClient` must be scriptable, not just static fixtures. Minimum scripts: OAuth success, OAuth denied, refresh success, `invalid_grant`, expired token gating, 429 then success, 500 then success, malformed shape, missing CUSIP, unknown enum, empty positions, removed position, working stop, replaced order chain, fill transaction, dividend/interest, fee transfer item, split/corporate-action placeholder.

Mappers must never crash a sync on unknown enums or missing optional fields. Unknown enum becomes `other` plus raw value. Missing CUSIP falls back to `instrumentId`, then `symbol+assetType` with `needs_review` audit. If identity is impossible, quarantine that row, preserve raw JSON, mark sync degraded, and continue.
