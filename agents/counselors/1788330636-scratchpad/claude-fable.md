**Verdict: not ready to commit.** Five things must change; the rest can follow.

**Must change before commit**

1. **Annotate can satisfy the post-mortem.** Trade.missing_post_mortem is `post_mortem: nil`. An agent note on a closed trade with no human words fills the column, so the trade leaves the EOD "missing post-mortems" list and the trade page shows the note as the human's line with the followed/improvised label. Refuse when the human's post-mortem is blank, or store agent notes in their own column. Also squish the note: a note containing a newline forges a `2026-09-02 human:` line, since the date-plus-actor stamp is the only signature. HTML is safe: every render goes through ERB escaping and the mailer escapes the body.

2. **The "never below the stop" rule is only true at 17:00.** Brief.stop_suggestions, Context.stop_suggestions and get_portfolio show any non-nil suggestion. A stop tightened during the day above last night's trail prints "trail 50 vs working stop 52". Re-apply `suggested_stop > stop_price` when reading, or null it in the orders sync when the working stop changes.

3. **Trail selection discards a valid trail.** `max_by` picks the higher of chandelier and ATR, then returns nil if it is at or above price. After a sharp drop the chandelier sits above the close while the ATR trail is still valid and below the stop ceiling; you get nothing. Pick the tightest trail that is below the latest close, and compare against `candles.last[:close]` as well as position.last_price, which comes from a sync that may be stale. The trail also skips the calculator's "latest candle within two trading days" gate, so a halted stock's old candles still produce a suggestion.

4. **Schedule order.** The EOD brief runs at 16:30 and the trail job at 17:00, so the EOD "tighten stop" line is always the previous day's trail. The label says "last night's" so it is honest, but the PRD's intent is nightly recompute feeding the EOD brief. Move the trail to about 16:15, or record the one-day lag in the plan.

5. **Lots caption is wrong and lots are not lots.** "instrument match only" is the wash-sale phrase. TaxLots.for lists every entry leg: earlier partial sales are not netted (the journal cannot know which lots Schwab consumed), and split ratios are not applied to leg quantity or price. Plug legs are handled honestly (unknown date, unknown term). Say "entry legs the journal saw, not net of earlier sales", and scale by the Ledger ratio or say that too.

**Later**

- **Long-term boundary.** `acquired <= 1.year.ago` calls exactly one year long-term; the rule is more than one year, measured at the sale date.
- **Lot method posture.** FIFO default is the right conservative choice. PRD 6a says to verify the schema before offering per-order selection in the UI; the select on the form and `taxLotMethod` in the sell payload are ahead of that. Shadow mode makes it harmless now.
- **Watchlist uniqueness is validation-only.** The index on (symbol, status) is not unique. Add a partial unique index where status is watching.
- **Watchlist writes aren't approver-gated**, unlike proposals. `drop!` overwrites the adder's user_id with the dropper (the audit row keeps both). Nothing ever sets `triggered`; proposing from the list does not mark the item.
- **Propose link** is safe: Rails encodes the query, the form re-escapes the value. A 2000-char thesis fits in a URL.
- **Prompt surface.** Agent-written triggers now sit in the system prompt frame. Rule 5 names memory files and tool results only; name the watching line too, and squish trigger and thesis so a newline cannot forge a frame line in the text email.
- **Suggestions carry no timestamp.** If the job stops running, get_portfolio presents an old suggestion under the positions sync stamp. Add `suggested_at` or clear all suggestions at job start.
- **Trade page edit box** is a single-line text field; after an annotation the human's next save flattens and replaces the agent lines. Use a textarea.

**Scheduled writes.** The trail job is the only new scheduled writer and touches just the two suggestion columns. The scheduled agent transport still filters to read-only tools, so annotate and watchlist cannot run unattended. The positions sync deletes sold rows, so suggestions die with the position.
