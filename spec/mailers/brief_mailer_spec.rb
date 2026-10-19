require "rails_helper"

RSpec.describe BriefMailer do
  let!(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let!(:whitney) { create(:user, email_address: "whitney@athayde.com", notify: true) } # reads the desk, and is never mailed

  def run(kind: :morning_brief, **attributes)
    AgentRun.new({ kind: kind, market_date: Date.new(2026, 9, 1), status: :succeeded, started_at: Time.current, finished_at: Time.current,
                       tool_turns: 3, tool_calls_count: 4, input_tokens: 1000, output_tokens: 200, estimated_cost: BigDecimal("0.0123"), stop_reason: "end_turn",
                       output_markdown: "All quiet.\n\nSuggested actions\n- none" }.merge(attributes))
  end

  it "frames the model's text with the token line, as-of stamps, the fixed calendar sentence, links, and the footer, to the approver alone" do
    create(:schwab_token)
    mail = described_class.brief(run)
    expect(mail.to).to eq(%w[ john@athayde.com ])
    expect(mail.subject).to eq("Athayde Desk: morning brief, Tue Sep 1")
    text = mail.text_part.body.to_s
    expect(text).to include("Schwab: healthy, token expires #{(Time.current + SchwabToken::REFRESH_LIFETIME).in_time_zone(MarketDay::ZONE).strftime('%a %b %-d')}",
                            "Earnings and economic calendar: not available until FMP (Phase 2.5).", "All quiet.", "3 turns · 4 tool calls", "$0.0123", "http://")
    expect(text).not_to include("stopped:")
    expect(described_class.brief(run(kind: :eod, tool_turns: 1, tool_calls_count: 1)).text_part.body.to_s).to include("1 turn · 1 tool call")
  end

  it "carries the watchlist on the morning brief and last night's tighten-stop suggestions on the end-of-day" do
    WatchlistItem.create!(symbol: "ABC", trigger: "close above 20", origin: :human)
    expect(described_class.brief(run).text_part.body.to_s).to include("Watching: ABC (close above 20)")
    account = create(:account, trading_enabled: true, account_type: "taxable")
    stop = create(:order, :working_stop, account: account, instrument: create(:instrument, symbol: "XYZ"), stop_price: 40)
    create(:position, account: account, instrument: stop.instrument, quantity: 10, working_stop_order: stop, suggested_stop: 44.5, suggested_stop_method: "chandelier", suggested_at: Time.current)
    text = described_class.brief(run(kind: :eod)).text_part.body.to_s
    expect(text).to include("Tighten stop", "XYZ: chandelier trail $44.50 vs working stop $40.00")
  end

  it "prefixes the subject and never carries dollar figures in it" do
    expect(described_class.brief(run(degraded: true, degraded_reasons: [ "positions are stale" ])).subject).to eq("DEGRADED: Athayde Desk: morning brief, Tue Sep 1")
    capped = described_class.brief(run(status: :capped, stop_reason: "max_tokens", error: "budget spent: output tokens"))
    expect(capped.subject).to eq("CAPPED: Athayde Desk: morning brief, Tue Sep 1")
    expect(capped.text_part.body.to_s).to include("The model's output was cut off; what follows is incomplete.\n\nAll quiet.", "stopped: max_tokens · budget spent: output tokens")
    expect(described_class.brief(run(kind: :eod)).subject).to eq("Athayde Desk: end of day, Tue Sep 1")
    failed = described_class.brief(run(status: :failed, error: "Anthropic RateLimitError: rate limited", output_markdown: nil, estimated_cost: nil))
    expect(failed.subject).to eq("FAILED: Athayde Desk: morning brief, Tue Sep 1")
    expect(failed.text_part.body.to_s).to include("The brief is unavailable: Anthropic RateLimitError", "unpriced")
  end

  it "escapes the model's text in the HTML part so a planted link or tag never renders" do
    html = described_class.brief(run(output_markdown: "Sell everything <a href=\"https://evil.example\">here</a> <script>x</script>")).html_part.body.to_s
    expect(html).to include("&lt;a href=", "&lt;script&gt;")
    expect(html).not_to include("<a href=\"https://evil.example\"")
    expect(html).to match(%r{<a href="http://[^"]+/">Dashboard</a>})
  end

  it "adds the day's fills, journal rows, missing post-mortems, and the snapshot to the end-of-day email from the database" do
    account = create(:account, trading_enabled: true, account_type: "taxable")
    create(:sync_run, feed: "activities", account: account)
    instrument = create(:instrument, symbol: "XYZ")
    at = Time.zone.parse("2026-09-01 10:15 EDT")
    fill(account, instrument, "BUY", 10, 50, at: at)
    fill(account, instrument, "SELL", 10, 55, at: at + 1.hour, status: "CANCELED")
    trade = create(:trade, account: account, instrument: instrument, status: :closed, closed_at: at, post_mortem: nil, needs_review: false, realized_pnl: 25)
    account.snapshots.create!(as_of: Date.new(2026, 9, 1), equity: 6500, drawdown: BigDecimal("0.0123"), open_risk_amount: 120, unprotected_count: 1)
    text = described_class.brief(run(kind: :eod)).text_part.body.to_s
    expect(text).to include("BUY 10 XYZ @ $50.00", "XYZ closed Tue Sep 1, 10:15 AM", "/trades/#{trade.id}", "Snapshot 2026-09-01: equity $6,500.00, drawdown 1.2%, open risk $120.00, unprotected 1")
    expect(text).not_to include("SELL 10 XYZ")
    12.times { |n| create(:trade, account: account, instrument: instrument, status: :closed, closed_at: at - n.days, post_mortem: nil, needs_review: false) }
    expect(described_class.brief(run(kind: :eod)).text_part.body.to_s).to include("and 3 more: http://", "filter=missing_post_mortem")
  end

  it "says the fills are unknown, not none, while the activities feed is stale" do
    create(:account, trading_enabled: true, account_type: "taxable")
    text = described_class.brief(run(kind: :eod)).text_part.body.to_s
    expect(text).to include("Fills today:\n  unknown: the activities feed is stale (last sync never)", "Journal rows touched today:\n  unknown")
    expect(text).not_to include("Fills today:\n  none")
  end

  it "says when today's snapshot is not yet written instead of showing an older one" do
    account = create(:account, trading_enabled: true, account_type: "taxable")
    create(:balance, account: account, equity: 6400, as_of: Time.zone.parse("2026-09-01 16:05 EDT"))
    account.snapshots.create!(as_of: Date.new(2026, 8, 31), equity: 6300)
    text = described_class.brief(run(kind: :eod)).text_part.body.to_s
    expect(text).to include("Today's snapshot is not yet written; equity $6,400.00 as of Tue Sep 1, 4:05 PM")
    expect(text).not_to include("Snapshot 2026-08-31")
  end

  it "sends the Sunday review with the re-auth link, token age, feeds, failures, and setup stats" do
    create(:schwab_token)
    create(:setup, name: "Breakout", sample_size: 3, win_rate: 0.67)
    mail = described_class.sunday_review(AgentRun.create!(kind: :sunday_review, status: :succeeded, started_at: Time.current, finished_at: Time.current))
    expect(mail.subject).to eq("Athayde Desk: Sunday review, re-authenticate Schwab")
    expect(mail.text_part.body.to_s).to include("/schwab/authorize", "Token: healthy", "Breakout: n=3, win rate 67.0%", "Allocation:", "Cash drag: not checked yet.", "Fund flow: none entered", "Research:", "no calibration computed yet")
  end

  it "sends the failure digest grouped by feed, kind, and job class" do
    account = create(:account, nickname: "Taxable")
    SyncRun.create!(feed: :orders, account: account, status: :failed, started_at: 2.hours.ago, finished_at: 2.hours.ago, error: "Schwab 503")
    AgentRun.create!(kind: :eod, market_date: Date.new(2026, 9, 1), status: :failed, started_at: 3.hours.ago, finished_at: 3.hours.ago, error: "deadline")
    AgentRun.create!(kind: :morning_brief, market_date: Date.new(2026, 9, 1), status: :succeeded, started_at: 5.hours.ago, finished_at: 5.hours.ago)
    text = described_class.failure_digest(FailureDigest.new).text_part.body.to_s
    expect(text).to include("Taxable · orders: 1 failed", "Schwab 503", "end of day, Tue Sep 1: failed: deadline", "morning brief, Tue Sep 1: succeeded but never emailed (bin/rails agent:resend[")
  end

  it "puts unresolved and not-placed submissions in the failure digest" do
    account = create(:account)
    unresolved = create(:order_proposal, account: account, instrument: create(:instrument, symbol: "XYZ"), status: "submission_unknown", quantity: 5)
    unresolved.submission_attempts.create!(attempted_at: 2.hours.ago, outcome: :unknown, payload: {}, response: { "error" => "timeout" })
    failed = create(:order_proposal, account: account, instrument: create(:instrument, symbol: "DEF"), status: "submission_failed", quantity: 7)
    failed.submission_attempts.create!(attempted_at: 3.hours.ago, outcome: :not_placed, payload: {}, response: { "error" => "not found at Schwab after two looks" })
    digest = FailureDigest.new
    expect(digest).not_to be_empty
    text = BriefMailer.failure_digest(digest).text_part.body.to_s
    expect(text).to include("Submission unresolved: BUY 5 XYZ, check Schwab", "Not placed: BUY 7 DEF", "not found at Schwab after two looks")
  end
end
