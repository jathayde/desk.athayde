# A desk ready to propose against: the starting rule set, a fresh balance, every feed synced, a year of candles.
module ProposalHelpers
  RULE_SET = { "max_risk_per_trade" => { "percent" => "1.0" }, "max_positions" => { "count" => "8" }, "max_position_exposure" => { "percent" => "25" },
               "max_sector_exposure" => {}, "daily_loss_halt" => { "percent" => "3" }, "max_drawdown_halt" => { "percent" => "10" }, "earnings_blackout" => {},
               "wash_sale" => { "days" => "30" }, "notional_cap" => { "per_order" => "2500", "per_day" => "5000" }, "stop_collar" => StopCollar::Calculator::DEFAULTS }.freeze

  def seed_rule_set(**overrides)
    RULE_SET.merge(overrides).each { |type, params| RiskRule.create!(rule_type: type, params: params, mode: type == "wash_sale" ? "warn" : "block") }
  end

  def ready_desk(account, equity: 10_000, settled: 3000)
    seed_rule_set
    create(:balance, account: account, equity: equity, settled_cash: settled, as_of: Time.current)
    %w[ positions orders activities ].each { |f| create(:sync_run, feed: f, account: account) }
    account.snapshots.create!(as_of: MarketDay.today - 1, equity: equity, drawdown: BigDecimal("0.02"))
    script_price_history
    account.reload
  end
end

RSpec.configure { |c| c.include ProposalHelpers }
