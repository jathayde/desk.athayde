# Seeded states for the clickable UI. Rows are written directly, never by driving jobs, and every time is
# relative so the state reads the same under either sync cadence.
module Playwright::Scenario
  extend self

  ACCOUNT_HASH = Schwab::FakeClient::ACCOUNT_HASH
  SCENARIOS = %w[ not_connected waiting_for_accounts needs_setup healthy expiring expired halted unprotected delisted sync_failed review_queue closed_trade
                  proposal proposal_warn proposal_blocked proposal_override submission_unknown rule_halted rebalance rebalance_skipped
                  allocation_desk thesis_review deposit_ask ].freeze

  # Guarded here as well as at the route: reset! empties the database.
  def load!(name)
    raise "scenarios are test-only" unless Rails.env.test? && Schwab.fake?
    name = name.to_s.tr("-", "_")
    raise ArgumentError, "unknown scenario #{name}" unless SCENARIOS.include?(name)
    reset!
    public_send(name)
  end

  def reset!
    Schwab::FakeClient.instance.reset!
    Rails.cache.clear
    [ Allocation::Drift, ThesisReview, DeploymentTranche, CashInflow, Allocation::Target, InstrumentTag, TradeLeg, Trade, Snapshot, Position, Balance, Activity, SubmissionAttempt, Order, OrderProposal, WatchlistItem, RiskRule, SyncRun, MarketDay, SchwabToken, Session, Account, Instrument, Setup ].each(&:delete_all)
    SystemSettings.instance.update!(shadow_mode: true, manual_halt: false, manual_halt_reason: nil, manual_halt_at: nil, sync_paused_reason: nil,
                                    rule_halt_rule: nil, rule_halt_reason: nil, rule_halt_tripped_at: nil, rule_halt_resets_at: nil)
    Rails.application.load_seed
    MarketDay.for(MarketDay.today)
  end

  def not_connected = nil

  def waiting_for_accounts = token!

  def needs_setup
    token!
    Account.create!(schwab_hash: ACCOUNT_HASH, account_type: nil, trading_enabled: false)
  end

  def healthy
    token!
    populate(account!)
  end

  def expiring
    token!(issued_at: 6.days.ago - 2.hours)
    populate(account!)
  end

  def expired
    token!(issued_at: 8.days.ago)
    populate(account!, synced_at: 3.hours.ago)
    SystemSettings.instance.update!(sync_paused_reason: "Schwab token unusable; re-authenticate")
    SyncRun.create!(feed: :positions, status: :skipped_token, started_at: 2.hours.ago, finished_at: 2.hours.ago, error: "token expired")
  end

  def halted
    healthy
    SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "daily loss limit, by hand", manual_halt_at: 1.hour.ago)
    AuditEvent.log("manual_halt_set", actor: :human, user: User.first, reason: "daily loss limit, by hand")
  end

  def unprotected
    healthy
    position = Position.find_by!(instrument: Instrument.find_by!(symbol: "DEF"))
    position.working_stop_order.update!(status: "CANCELED")
    position.update!(working_stop_order: nil)
  end

  # A validated entry waiting for the approver, with the two not-checked rules to acknowledge.
  def proposal
    proposal_desk
    propose
  end

  # The same entry after a taxable loss on XYZ this month: the wash-sale caution to acknowledge.
  def proposal_warn
    proposal_desk
    Account.first.trades.create!(instrument: Instrument.find_by!(symbol: "XYZ"), status: :closed, avg_entry: 60, avg_exit: 55, peak_quantity: 10, realized_pnl: -50, initial_risk: 30, realized_r: -1.67,
                                 opened_at: 20.days.ago, closed_at: 10.days.ago)
    propose
  end

  # Over the per-order notional cap: rejected by rules, nothing to approve.
  def proposal_blocked
    proposal_desk
    RiskRule.active_for("notional_cap").supersede!(params: { "per_order" => "1000", "per_day" => "5000" }, user: User.first, note: "tight for the demo")
    propose
  end

  # A stop far below the collar: approvable only with a reason.
  def proposal_override
    proposal_desk
    propose(stop_price: BigDecimal("30"))
  end

  # Last night's check found XYZ overweight against a 15 percent target and proposed trimming it.
  def rebalance
    drift = overweight_xyz(action: "reported")
    proposal = Proposals::Create.call(account: Account.first, kind: :rebalance, side: :sell, instrument: drift.target.instrument, quantity: 11, limit_price: drift.close,
                                      origin: :allocation, allocation_source: drift, expires_at: 1.day.from_now, thesis: "Rebalance XYZ toward 15.0% of equity.")
    drift.update!(action: "proposed", order_proposal: proposal)
  end

  # The same overweight, but a human sell on XYZ was already waiting, so the check stepped aside.
  def rebalance_skipped
    overweight_xyz(action: "existing_proposal")
    Proposals::Create.call(account: Account.first, kind: :exit, side: :sell, symbol: "XYZ", limit_price: BigDecimal("54"), quantity: 5, thesis: "Trimming into strength.", origin: :human, user: User.first)
  end

  # A healthy desk with the book rules and an ask-each-time policy, no targets yet: the targets screen from empty.
  def allocation_desk
    proposal_desk
  end

  # TQQQ, tagged amplified and held, drifted past its target: a thesis review with the journal's thesis.
  def thesis_review
    proposal_desk
    account = Account.first
    tqqq = Instrument.create!(symbol: "TQQQ", cusip: "74347X831", asset_type: "EQUITY")
    tqqq.classify!(asset_class: nil, tags: %w[ amplified ], user: User.first)
    account.positions.create!(instrument: tqqq, quantity: 30, average_price: 60, cost_basis: 1800, market_value: 2100, last_price: 70, synced_at: Time.current)
    account.trades.create!(instrument: tqqq, status: :open, thesis: "Levered Nasdaq into the cutting cycle.")
    target = Allocation::Target.add!(symbol: "TQQQ", target_percent: "10", user: User.first)
    drift = target.drifts.create!(as_of: MarketDay.today.prev_weekday, weight: BigDecimal("0.205"), target_weight: BigDecimal("0.1"), band: BigDecimal("0.05"), close: 70,
                                  drift: BigDecimal("0.105"), notional: BigDecimal("-1075.2"), quantity: 15, action: "thesis_review")
    drift.update!(thesis_review: ThesisReview.raise_for!(account: account, drift: drift))
  end

  # A deposit under the ask-each-time policy, waiting for the operator's answer.
  def deposit_ask
    proposal_desk
    Allocation::Target.add!(symbol: "XYZ", target_percent: "30", user: User.first)
    activity = Account.first.activities.create!(broker_activity_id: "deposit-1", kind: :deposit, status: Schwab::Activity::VALID, net_amount: 2500, trade_date: MarketDay.today, executed_at: Time.current)
    CashInflow.create_from!(Account.first, activity, DeploymentPolicy.current)
  end

  # An approve that got no answer from Schwab, still being looked for: through the state machine, never by hand.
  def submission_unknown
    proposal_desk
    proposal = propose
    attempt = proposal.start_submission!(user: User.first, acknowledged: proposal.warnings, override_reason: nil, payload: {}, shadow: false)
    proposal.record_unknown!(attempt, error: "Net::ReadTimeout")
  end

  # The daily-loss rule tripped: entries refused, exits still allowed.
  def rule_halted
    proposal_desk
    SystemSettings.instance.trip_rule_halt!(rule: "daily_loss_halt", reason: "down 3.2% today", resets_at: nil)
  end

  def delisted
    healthy
    position = Position.find_by!(instrument: Instrument.find_by!(symbol: "DEF"))
    position.instrument.delist!(user: User.first, price: position.last_price)
  end

  # The failure is the latest thing that happened to the orders feed, so it is still unresolved.
  def sync_failed
    token!
    populate(account!, synced_at: 10.minutes.ago)
    SyncRun.create!(feed: :orders, account: Account.first, status: :failed, started_at: 5.minutes.ago, finished_at: 5.minutes.ago, error: "Schwab responded 503")
  end

  def review_queue
    healthy
    account = Account.first
    %w[ LBAS SLV ].each do |symbol|
      instrument = Instrument.create!(symbol: symbol, cusip: SecureRandom.hex(4).upcase.ljust(9, "0"), asset_type: "EQUITY")
      account.positions.create!(instrument: instrument, quantity: 10, average_price: 20, cost_basis: 200, market_value: 210, last_price: 21, synced_at: Time.current)
      trade = account.trades.create!(instrument: instrument, status: :open, needs_review: true, review_reason: "bootstrapped", bootstrapped: true, avg_entry: 20, quantity: 10, peak_quantity: 10)
      trade.trade_legs.create!(kind: :entry, quantity: 10, price: 20, cash_amount: -200, note: "plug")
    end
  end

  def closed_trade
    healthy
    account = Account.first
    xyz = Instrument.find_by!(symbol: "XYZ")
    trade = account.trades.create!(instrument: xyz, status: :closed, avg_entry: 51.18, avg_exit: 55.31, peak_quantity: 40, realized_pnl: 165.2, initial_risk: 91.2, realized_r: 1.81,
                                   planned_stop: 48.9, setup: Setup.create!(name: "breakout-A"), opened_at: 5.days.ago, closed_at: 1.day.ago)
    trade.trade_legs.create!(kind: :entry, quantity: 40, price: 51.18, cash_amount: -2047.2, executed_at: 5.days.ago)
    trade.trade_legs.create!(kind: :exit, quantity: 40, price: 55.31, cash_amount: 2212.4, executed_at: 1.day.ago)
  end

  private
    def proposal_desk
      healthy
      User.first.update!(approver: true)
      RiskRule.active_for("max_position_exposure").supersede!(params: { "percent" => "60" }, user: User.first, note: "a scale-in on a held name") # the seeds carry the rest
      Account.first.balances.create!(as_of: Time.current, equity: 10_240, settled_cash: 5000, unsettled_cash: 0, cash_available_for_trading: 5000)
      Schwab::FakeClient.instance.script_daily_history(symbol: "XYZ", close: 50) # the fake's quote fixture already knows XYZ
    end

    def overweight_xyz(action:)
      proposal_desk
      target = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: User.first)
      target.drifts.create!(as_of: MarketDay.today.prev_weekday, weight: BigDecimal("0.207"), target_weight: BigDecimal("0.15"), band: BigDecimal("0.05"), close: 53,
                            drift: BigDecimal("0.057"), notional: BigDecimal("-583.68"), quantity: 11, action: action, detail: { "one_share" => "0.005176" })
    end

    def propose(stop_price: BigDecimal("47"))
      Proposals::Create.call(account: Account.first, kind: :entry, side: :buy, symbol: "XYZ", limit_price: BigDecimal("50"), stop_price: stop_price, thesis: "Adding to the base breakout on volume.", origin: :agent)
    end

    def token!(issued_at: Time.current)
      SchwabToken.create!(access_token: "fake-access", refresh_token: "fake-refresh", issued_at: issued_at, access_expires_at: issued_at + 29.minutes,
                          refresh_expires_at: issued_at + SchwabToken::REFRESH_LIFETIME, scope: "api")
    end

    def account! = Account.create!(schwab_hash: ACCOUNT_HASH, account_type: :taxable, trading_enabled: true, nickname: "Taxable")

    def populate(account, synced_at: Time.current)
      %w[ XYZ DEF LBAS SLV ].each { |symbol| Schwab::FakeClient.instance.script_daily_history(symbol: symbol, close: 50) }
      account.balances.create!(as_of: synced_at, equity: 10_240, settled_cash: 2_110, unsettled_cash: 980, cash_available_for_trading: 3_090)
      account.snapshots.create!(as_of: MarketDay.today.prev_weekday, equity: 10_180, index_value: 1, high_water_index: 1)
      { "XYZ" => [ 40, 51.18, 53.0, 48.9 ], "DEF" => [ 15, 88.02, 86.57, 85.6 ] }.each do |symbol, (qty, avg, last, stop)|
        instrument = Instrument.create!(symbol: symbol, cusip: symbol == "XYZ" ? "037833100" : "594918104", asset_type: "EQUITY")
        stop_order = account.orders.create!(instrument: instrument, broker_order_id: "stop-#{symbol}", status: Schwab::Order::WORKING, side: Schwab::Order::SELL, order_type: Schwab::Order::STOP_TYPES.first,
                                             quantity: qty, remaining_quantity: qty, stop_price: stop, entered_at: 2.days.ago)
        account.positions.create!(instrument: instrument, quantity: qty, average_price: avg, cost_basis: qty * avg, market_value: qty * last, last_price: last,
                                  working_stop_order: stop_order, synced_at: synced_at)
      end
      %w[ positions orders activities ].each { |feed| SyncRun.create!(feed: feed, account: account, status: :succeeded, started_at: synced_at, finished_at: synced_at, window_to: synced_at) }
    end
end
