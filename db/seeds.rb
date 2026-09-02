# Access is by allowlist: only seeded users can request a sign-in link. This part runs everywhere, including
# the production release phase (db:prepare seeds a fresh database).
[ { email_address: "john@athayde.com", name: "John", approver: true }, { email_address: "whitney@athayde.com", name: "Whitney", approver: false } ].each do |attributes|
  User.find_or_initialize_by(email_address: attributes[:email_address]).update!(attributes)
end

# The starting guardrail set (PRD §5.4), global rows the rule editor supersedes; idempotent by the one-active index.
{ "max_risk_per_trade" => { "percent" => "1.0" }, "max_positions" => { "count" => "8" }, "max_position_exposure" => { "percent" => "25" },
  "max_sector_exposure" => {}, "daily_loss_halt" => { "percent" => "3" }, "max_drawdown_halt" => { "percent" => "10" },
  "earnings_blackout" => {}, "wash_sale" => { "days" => "30" }, "notional_cap" => { "per_order" => "2500", "per_day" => "5000" },
  "stop_collar" => StopCollar::Calculator::DEFAULTS }.each do |rule_type, params|
  RiskRule.active_for(rule_type) || RiskRule.create!(rule_type: rule_type, params: params, mode: rule_type == "wash_sale" ? "caution" : "block", note: "seeded starting set")
end

# A development desk through the fake broker and the fake model, so every screen and a brief render without
# Schwab or Anthropic. Never in production, never against the real adapters, never twice.
return unless Rails.env.development? && Schwab.fake? && Agent.fake?
return puts("desk already seeded; bin/rails db:reset to start over") if Account.any?

ActiveJob::Base.queue_adapter = :inline # the sync jobs hand off to the journal with perform_later
Schwab::FakeClient.instance.reset!

now = Time.current
SchwabToken.create!(access_token: "fake-access", refresh_token: "fake-refresh", issued_at: now, access_expires_at: now + 29.minutes,
                    refresh_expires_at: now + SchwabToken::REFRESH_LIFETIME, scope: "api")
(MarketDay.today..MarketDay.today + 7).each { |date| MarketDay.for(date) }

Sync::AccountsJob.perform_now
account = Account.first.tap { |a| a.update!(account_type: :taxable, trading_enabled: true, nickname: "Taxable") }
Sync::PositionsJob.perform_now(account)
Sync::OrdersJob.perform_now(account)
Sync::ActivitiesJob.perform_now(account)
Journal::BootstrapJob.perform_now(account)
Journal::LinkFillsJob.perform_now(account)

# One setup, one reviewed trade, one left in the review queue, one closed trade with an R so the stats have a row.
john = User.find_by!(email_address: "john@athayde.com")
breakout = Setup.create!(name: "Breakout", definition: "Buy the break of a tight range on volume; stop under the range low.")
reviewed, *queued = account.trades.needing_review.order(:id).to_a
reviewed&.review!(setup: breakout, planned_stop: reviewed.avg_entry * BigDecimal("0.95"), thesis: "Seeded thesis: range break on volume.", user: john)
queued.first&.defer_review! # one trade stays in the review queue, skipped once
closed = account.trades.create!(instrument: Instrument.find_by!(symbol: "XYZ"), status: :closed, setup: breakout, avg_entry: 51.18, avg_exit: 55.31, peak_quantity: 40,
                                realized_pnl: 165.2, initial_risk: 91.2, realized_r: 1.81, planned_stop: 48.9, opened_at: 9.days.ago, closed_at: 2.days.ago,
                                thesis: "Seeded closed trade.", followed_setup: true)
closed.trade_legs.create!(kind: :entry, quantity: 40, price: 51.18, cash_amount: -2047.2, executed_at: 9.days.ago)
closed.trade_legs.create!(kind: :exit, quantity: 40, price: 55.31, cash_amount: 2212.4, executed_at: 2.days.ago)
Journal::RecomputeSetupStatsJob.perform_now(breakout)

# A short equity history so drawdown and day change have something to read, and one failed run for the system page.
balance = account.current_balance
[ 3, 2, 1 ].each_with_index do |days_ago, i|
  account.snapshots.create!(as_of: MarketDay.today - days_ago, equity: balance.equity - 60 + i * 20, index_value: 1 + i * 0.002, high_water_index: 1.004,
                            drawdown: [ 0.004 - i * 0.002, 0 ].max, open_risk_amount: 120, open_risk_ratio: 0.012, unprotected_count: 0)
end
SyncRun.create!(feed: :orders, account: account, status: :failed, started_at: 2.hours.ago, finished_at: 2.hours.ago, error: "seeded: Schwab 503 (see /system)")

# One brief through the fake model for the most recent weekday; the email lands in tmp/mails.
brief_day = MarketDay.today
brief_day -= 1 until brief_day.on_weekday?
Agent::MorningBriefJob.perform_now(brief_day)
puts "seeded: #{Account.count} account, #{Position.count} positions, #{Trade.count} trades, #{Setup.count} setup, #{AgentRun.count} brief (email in tmp/mails)"
