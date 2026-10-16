require "rails_helper"

RSpec.describe Allocation::Planner do
  let(:zone) { Time.find_zone!("America/New_York") }
  let(:wednesday) { zone.local(2026, 10, 14, 16) }
  let!(:token) { create(:schwab_token) }
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let!(:def_) { create(:instrument, symbol: "DEF", cusip: "594918104") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  before do
    travel_to wednesday + 70.minutes
    seed_rule_set
    { "rebalance_band" => { "percent" => "5" }, "min_rebalance_notional" => { "amount" => "100" } }.each { |type, params| RiskRule.create!(rule_type: type, params: params) }
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 53, market_value: 2120)
    synced_after_close(wednesday)
  end

  after { travel_back }

  def synced_after_close(closed_at)
    create(:balance, account: account, equity: 10_000, settled_cash: 3000, as_of: closed_at + 45.minutes)
    create(:sync_run, feed: "positions", account: account, started_at: closed_at + 50.minutes, finished_at: closed_at + 50.minutes)
  end

  def run = Allocation::DriftJob.perform_now
  def drift(target, on: Date.current) = target.drifts.find_by!(as_of: on)

  it "proposes a rebalance buy that lives through the next session, judged as a buy that opens exposure but carries no stop" do
    target = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    run
    proposal = drift(target).order_proposal
    expect(proposal).to have_attributes(kind: "rebalance", side: "buy", quantity: 11, limit_price: BigDecimal("86.57"), status: "validated", stop_price: nil,
                                        expires_at: zone.local(2026, 10, 15, 16), thesis: a_string_starting_with("Rebalance DEF toward 10.0% of equity"))
    results = proposal.guardrail_results
    expect(results.values_at("position_coverage", "stop_collar", "max_risk_per_trade").map { |r| r["outcome"] }).to all(eq("skipped"))
    expect(results.values_at("settled_cash", "notional_cap", "max_positions", "max_position_exposure", "halt").map { |r| r["outcome"] }).to all(eq("pass"))
    expect(results).not_to have_key("rebalance_band")
    expect(AuditEvent.where(kind: "proposal_created", subject: proposal).sole.actor).to eq("system")

    travel_to zone.local(2026, 10, 15, 7)
    expect(OrderProposal.expiring).not_to include(proposal) # proposed after the close, decided in the morning
  end

  it "proposes a rebalance sell that takes the exit's lot method, and approves in shadow as a plain limit with no child" do
    target = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    run
    proposal = drift(target).order_proposal
    expect(proposal).to have_attributes(side: "sell", quantity: 11, limit_price: 53, tax_lot_method: Schwab::Order::DEFAULT_TAX_LOT_METHOD)
    expect(proposal.guardrail_results.dig("position_coverage", "outcome")).to eq("pass")
    proposal.approve_and_submit!(user: john, acknowledged: proposal.warnings)
    expect(proposal.reload).to be_submitted.and be_shadow
    payload = proposal.latest_attempt.payload
    expect(payload).to include("orderType" => "LIMIT", "price" => "53.00", "orderStrategyType" => "SINGLE")
    expect(payload).not_to have_key("childOrderStrategies")

    buy = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    Allocation::Drift.where(target: buy).delete_all
    run
    approved = drift(buy).order_proposal
    approved.approve_and_submit!(user: john, acknowledged: approved.warnings)
    expect(approved.reload.latest_attempt.payload).to include("orderLegCollection" => [ hash_including("instruction" => "BUY", "quantity" => 11) ], "orderStrategyType" => "SINGLE")
    expect(approved.latest_attempt.payload).not_to have_key("childOrderStrategies")
  end

  it "holds a class, a leveraged or amplified instrument, a sub-minimum order, and a halted desk at reported, saying why" do
    bonds = Allocation::Target.add!(asset_class: "bonds", target_percent: "20", user: john)
    def_.classify!(asset_class: nil, tags: %w[ leveraged ], user: john)
    leveraged = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    small = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    RiskRule.active_for("min_rebalance_notional").supersede!(params: { "amount" => "1000" }, user: john)
    run
    expect(drift(bonds)).to have_attributes(action: "reported", order_proposal: nil)
    expect(drift(leveraged)).to have_attributes(action: "reported", detail: hash_including("held_for" => "thesis review"))
    expect(drift(small)).to have_attributes(action: "reported", detail: hash_including("below_minimum" => "1000.0"))
    expect(OrderProposal.count).to eq(0)

    RiskRule.active_for("min_rebalance_notional").supersede!(params: { "amount" => "100" }, user: john)
    SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "weird day")
    Allocation::Drift.delete_all
    run
    expect(drift(small)).to have_attributes(action: "reported", detail: hash_including("refused" => "halted: weird day"))
  end

  it "steps aside for any waiting proposal on the instrument, and a human proposal after it is refused in words" do
    script_price_history
    Proposals::Create.call(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 54, quantity: 5, origin: :human, user: john)
    target = Allocation::Target.add!(symbol: "XYZ", target_percent: "40", user: john) # wants a buy; the waiting sell still blocks it
    run
    expect(drift(target)).to have_attributes(action: "existing_proposal", order_proposal: nil)

    target.retire!(user: john)
    buy = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    run
    expect(drift(buy).order_proposal).to be_validated
    script_price_history(symbol: "DEF", close: 86)
    expect { Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "DEF", limit_price: 86, stop_price: 83, origin: :human, user: john) }
      .to raise_error(Proposals::Create::Refused, /already has a buy proposal waiting/)
  end

  it "does not ask again after a rejection while the drift stays on the same side, until the operator clears it" do
    target = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    run
    drift(target).order_proposal.reject!(user: john, reason: "holding the overweight on purpose")

    thursday = zone.local(2026, 10, 15, 16)
    travel_to thursday + 70.minutes
    synced_after_close(thursday)
    run
    expect(drift(target)).to have_attributes(action: "rejected_standing", order_proposal: nil)

    target.clear_rejection!(user: john)
    expect(AuditEvent.where(kind: "allocation_target_changed").last.data["after"]).to have_key("rejection_cleared_at")
    Allocation::Drift.where(as_of: Date.current).delete_all
    run
    expect(drift(target)).to have_attributes(action: "proposed")
  end

  it "takes a proposal the database refuses as that row's verdict, and the rest of the run goes on" do
    target = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    run
    drift(target).order_proposal.expire!
    drift(target).update_columns(order_proposal_id: nil, action: "reported") # the row forgot its proposal; the one-per-source index has not
    other = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    run
    expect(drift(target)).to have_attributes(action: "reported", detail: hash_including("refused" => "XYZ already has a sell proposal waiting; decide it first"))
    expect(drift(other)).to have_attributes(action: "proposed")
  end

  it "keeps a rejection standing through a night that could not be measured" do
    target = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    run
    drift(target).order_proposal.reject!(user: john, reason: "not now")
    target.drifts.create!(as_of: Date.new(2026, 10, 15), target_weight: target.target_weight, action: "unavailable", detail: { "reasons" => [ "quotes down" ] })
    expect(target.rejection_standing?("sell", before: Date.new(2026, 10, 16))).to be(true)
    expect(target.rejection_standing?("buy", before: Date.new(2026, 10, 16))).to be(false)
  end

  it "steps aside for a shadow approval still awaiting hand placement and for a submission pending reconciliation" do
    target = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    run
    first = drift(target).order_proposal
    first.approve_and_submit!(user: john, acknowledged: first.warnings)
    expect(first.reload).to be_awaiting_hand_placement
    expect(first.latest_attempt.payload).to include("taxLotMethod" => Schwab::Order::DEFAULT_TAX_LOT_METHOD)

    thursday = zone.local(2026, 10, 15, 16)
    travel_to thursday + 70.minutes
    synced_after_close(thursday)
    run
    expect(drift(target)).to have_attributes(action: "existing_proposal", order_proposal: nil)

    first.update_columns(status: "submission_unknown")
    Allocation::Drift.where(as_of: Date.current).delete_all
    run
    expect(drift(target).action).to eq("existing_proposal")
  end

  it "records a rebalance the rules block as reported with the blocking rules, keeping the proposal on the row" do
    target = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    RiskRule.active_for("notional_cap").supersede!(params: { "per_order" => "500", "per_day" => "5000" }, user: john)
    run
    expect(drift(target)).to have_attributes(action: "reported", detail: hash_including("refused" => "blocked by notional cap"))
    expect(drift(target).order_proposal).to be_rejected_by_rules
  end

  it "under a rule halt proposes the sell that reduces a position and refuses the buy that opens one" do
    sell = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    buy = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    SystemSettings.instance.trip_rule_halt!(rule: "daily_loss_halt", reason: "down 3%", resets_at: 1.day.from_now)
    run
    expect(drift(sell)).to have_attributes(action: "proposed")
    expect(drift(buy)).to have_attributes(action: "reported", detail: hash_including("refused" => /entries are halted by daily_loss_halt/))
  end

  it "counts an approved rebalance buy toward the day's notional, so the next one sees it" do
    target = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    run
    proposal = drift(target).order_proposal
    proposal.approve_and_submit!(user: john, acknowledged: proposal.warnings)
    expect(Guardrails::Context.new(account).notional_today).to eq(proposal.cost)
  end

  it "goes on to the next target when planning one raises, writing that row with the error" do
    broken = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    fine = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    allow_any_instance_of(Instrument).to receive(:tagged?).and_wrap_original { |original, *args| original.receiver.symbol == "XYZ" ? raise("tags unreadable") : original.call(*args) }
    run
    expect(drift(broken)).to have_attributes(action: "reported", weight: BigDecimal("0.212"), detail: hash_including("error" => "tags unreadable"))
    expect(drift(fine)).to have_attributes(action: "proposed")
  end

  it "expires a Friday proposal at Monday's close, skips a holiday, and proposes nothing when Schwab's calendar is missing" do
    friday = zone.local(2026, 10, 16, 16)
    travel_to friday + 70.minutes
    synced_after_close(friday)
    target = Allocation::Target.add!(symbol: "DEF", target_percent: "10", user: john)
    Schwab::FakeClient.instance.close_market_on(Date.new(2026, 10, 19))
    run
    expect(drift(target).order_proposal.expires_at).to eq(zone.local(2026, 10, 20, 16))

    drift(target).order_proposal.expire!
    Allocation::Drift.delete_all
    MarketDay.where(date: Date.new(2026, 10, 19)..).delete_all
    Schwab::FakeClient.instance.enqueue(:market_hours, sticky: true) { raise Schwab::ServerError, "hours down" }
    run
    expect(drift(target)).to have_attributes(action: "reported", detail: hash_including("reason" => "the next session is not known from Schwab's calendar"))
  end

  it "lifts a standing rejection once the drift is back inside the band or changes side" do
    target = Allocation::Target.add!(symbol: "XYZ", target_percent: "15", user: john)
    run
    drift(target).order_proposal.reject!(user: john, reason: "not now")
    later = Date.new(2026, 10, 16)
    expect(target.rejection_standing?("sell", before: later)).to be(true)
    inside = target.drifts.create!(as_of: Date.new(2026, 10, 15), target_weight: target.target_weight, drift: BigDecimal("0.01"), band: BigDecimal("0.05"), notional: -100, action: "none")
    expect(target.rejection_standing?("sell", before: later)).to be(false)
    inside.update!(drift: BigDecimal("-0.07"), notional: 700, action: "reported")
    expect(target.rejection_standing?("sell", before: later)).to be(false)
  end
end
