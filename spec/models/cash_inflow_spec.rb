require "rails_helper"

RSpec.describe CashInflow do
  include ActiveJob::TestHelper

  let(:zone) { Time.find_zone!("America/New_York") }
  let(:wednesday) { zone.local(2026, 10, 14, 16) }
  let!(:token) { create(:schwab_token) }
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let!(:def_) { create(:instrument, symbol: "DEF", cusip: "594918104") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true, notify: true) }

  before do
    travel_to wednesday + 70.minutes
    seed_rule_set
    RiskRule.active_for("max_position_exposure").supersede!(params: { "percent" => "60" }, user: john)
    { "rebalance_band" => { "percent" => "5" }, "min_rebalance_notional" => { "amount" => "100" } }.each { |type, params| RiskRule.create!(rule_type: type, params: params) }
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 53, market_value: 2120)
    synced_after_close(wednesday)
  end

  after { travel_back }

  def synced_after_close(closed_at, settled: 3000)
    create(:balance, account: account, equity: 10_000, settled_cash: settled, as_of: closed_at + 45.minutes)
    create(:sync_run, feed: "positions", account: account, started_at: closed_at + 50.minutes, finished_at: closed_at + 50.minutes)
  end

  def deposit(amount, on: Date.new(2026, 10, 14)) = create(:activity, account: account, instrument: nil, kind: "deposit", side: nil, quantity: nil, price: nil, net_amount: amount, trade_date: on, executed_at: on.in_time_zone(zone).change(hour: 9))
  def policy!(mode, weeks: nil) = DeploymentPolicy.create!(mode: mode, weeks: weeks, created_at: zone.local(2026, 10, 1))

  it "detects each new deposit once from the day the desk first had a policy, leaving a small one as cash" do
    policy!("immediate")
    deposit(5000, on: Date.new(2026, 9, 20)) # before the desk had a policy: history, not new cash
    small = deposit(50)
    big = deposit(2000)
    expect(described_class.detect!(account).map(&:activity)).to eq([ small, big ])
    expect(described_class.detect!(account)).to be_empty
    expect(described_class.find_by!(activity: small)).to have_attributes(status: "done", detail: { "below_minimum" => "100.0" })
    expect(described_class.find_by!(activity: big)).to have_attributes(status: "pending", amount: 2000, deployment_policy: DeploymentPolicy.current)
    expect(AuditEvent.where(kind: "cash_inflow_detected").count).to eq(2)
  end

  it "deploys at once at tonight's check, pro-rata to the instrument targets by weight, with the notes frozen, and pauses drift buys until then" do
    policy!("immediate")
    Allocation::Target.add!(symbol: "XYZ", target_percent: "40", user: john) # underweight by 18.8 points: a drift buy
    Allocation::Target.add!(symbol: "DEF", target_percent: "20", user: john)
    Allocation::Target.add!(asset_class: "bonds", target_percent: "20", user: john)
    deposit(2000)
    inflow = described_class.detect!(account).sole
    travel 1.minute # detected before the check began
    allow(Memory::Repo).to receive(:configured).and_return(instance_double(Memory::Repo, text: "Lump sum beats staging about two thirds of the time."))
    Allocation::DriftJob.perform_now

    xyz_drift = Allocation::Drift.joins(:target).find_by!(allocation_targets: { instrument_id: xyz.id })
    expect(xyz_drift).to have_attributes(action: "reported", detail: hash_including("committed" => true))
    buys = OrderProposal.where(allocation_source: inflow).order(:id)
    expect(buys.map { |p| [ p.instrument.symbol, p.quantity.to_i, p.limit_price ] }).to eq([ [ "XYZ", 25, 53 ], [ "DEF", 7, BigDecimal("86.57") ] ]) # $1,333.33 and $666.66
    expect(buys.first.context).to include("source" => "$2,000.00 deposited Oct 14", "share" => "1333.33", "notes" => "Lump sum beats staging about two thirds of the time.")
    expect(inflow.reload).to have_attributes(status: "proposed", detail: hash_including("proposed" => 2, "outcomes" => { "XYZ" => "proposed", "DEF" => "proposed" }))
  end

  it "stages over weeks, proposes each tranche on its day, rolls one that buys nothing, and is done when the last is" do
    policy!("staged", weeks: 3)
    Allocation::Target.add!(symbol: "DEF", target_percent: "20", user: john)
    deposit(2000)
    inflow = described_class.detect!(account).sole
    tranches = inflow.tranches
    expect(tranches.map { |t| [ t.due_on, t.amount ] }).to eq([ [ Date.new(2026, 10, 14), BigDecimal("666.66") ], [ Date.new(2026, 10, 21), BigDecimal("666.66") ], [ Date.new(2026, 10, 28), BigDecimal("666.68") ] ])
    expect(inflow).to be_status_staged

    Allocation::DriftJob.perform_now
    expect(tranches.first.reload).to be_proposed
    expect(OrderProposal.where(allocation_source: tranches.first).sole).to have_attributes(quantity: 7)

    OrderProposal.update_all(status: "filled")
    tranches.second.update!(amount: 50) # under one share of DEF
    travel_to zone.local(2026, 10, 21, 17, 10)
    synced_after_close(zone.local(2026, 10, 21, 16))
    Allocation::DriftJob.perform_now
    expect(tranches.second.reload).to be_rolled
    expect(tranches.third.reload.amount).to eq(BigDecimal("716.68"))

    tranches.third.update!(amount: 50)
    travel_to zone.local(2026, 10, 28, 17, 10)
    synced_after_close(zone.local(2026, 10, 28, 16))
    Allocation::DriftJob.perform_now
    expect(tranches.third.reload).to have_attributes(status: "done", detail: { "left_as_cash" => "50.0", "outcomes" => { "DEF" => "under one share" } })
    expect(inflow.reload).to be_status_done
  end

  it "asks when the policy says so, and the answer deploys tonight, stages, or holds as cash" do
    policy!("ask", weeks: nil)
    deposit(2000)
    asked = perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) { described_class.detect!(account).sole }
    review = asked.thesis_review
    expect(review).to have_attributes(reason: "deployment_ask", instrument: nil, label: "$2,000.00 deposited Oct 14")
    expect(ActionMailer::Base.deliveries.map(&:subject)).to include("Athayde Desk: $2,000.00 deposited Oct 14: deploy, stage, or hold?")
    expect { review.decide!(decision: "exit", user: john) }.to raise_error(ArgumentError, "choose deploy, stage, or hold")
    expect { review.decide!(decision: "stage", weeks: "0", user: john) }.to raise_error(ArgumentError, "stage over 1 to 52 weeks")
    expect(review.reload).to be_open
    travel_to zone.local(2026, 10, 28, 10) # answered two weeks late: staging starts today, not at the deposit
    review.decide!(decision: "stage", weeks: "2", user: john)
    expect(asked.reload).to have_attributes(status: "staged")
    expect(asked.tranches.map { |t| [ t.week, t.due_on ] }).to eq([ [ 1, Date.new(2026, 10, 28) ], [ 2, Date.new(2026, 11, 4) ] ])
    expect(asked.default_weeks).to eq(CashInflow::DEFAULT_WEEKS) # an ask policy names no weeks

    second = described_class.create_from!(account, deposit(1500, on: Date.new(2026, 10, 15)), DeploymentPolicy.current)
    second.thesis_review.decide!(decision: "hold", reason: "keeping it for taxes", user: john)
    expect(second.reload).to have_attributes(status: "held", detail: hash_including("reason" => "keeping it for taxes"))
  end

  it "leaves new cash pending, not spent, on a night with no next session on Schwab's calendar or no measured target" do
    policy!("immediate")
    inflow = (deposit(2000) && described_class.detect!(account).sole)
    Allocation::DriftJob.perform_now # no targets at all
    expect(inflow.reload).to be_status_pending

    Allocation::Target.add!(symbol: "DEF", target_percent: "20", user: john)
    MarketDay.where(date: Date.new(2026, 10, 15)..).delete_all
    Schwab::FakeClient.instance.enqueue(:market_hours, sticky: true) { raise Schwab::ServerError, "hours down" }
    Allocation::Drift.delete_all
    Allocation::DriftJob.perform_now
    expect(inflow.reload).to be_status_pending
    expect(OrderProposal.count).to eq(0)
  end

  def night(date, settled: 3000)
    travel_to zone.local(date.year, date.month, date.day, 17, 10)
    synced_after_close(zone.local(date.year, date.month, date.day, 16), settled: settled)
    Allocation::DriftJob.perform_now
  end

  it "waits for unsettled cash without proposing or alerting, deploys once it settles, and gives up after five nights" do
    policy!("immediate")
    Allocation::Target.add!(symbol: "DEF", target_percent: "20", user: john)
    Balance.update_all(settled_cash: 0)
    deposit(2000)
    inflow = described_class.detect!(account).sole
    travel 1.minute
    Allocation::DriftJob.perform_now
    expect(inflow.reload).to have_attributes(status: "pending", detail: hash_including("deferred_nights" => 1, "outcomes" => { "DEF" => "waiting for settled cash" }))
    expect(OrderProposal.count).to eq(0) # no blocked row, no alert, each night
    night(Date.new(2026, 10, 15), settled: 3000)
    expect(inflow.reload).to be_status_proposed
    expect(OrderProposal.sole).to have_attributes(quantity: 23, allocation_source: inflow) # the only target takes all $2,000

    later = described_class.create_from!(account, deposit(1500, on: Date.new(2026, 10, 16)), DeploymentPolicy.current)
    OrderProposal.update_all(status: "filled")
    [ 16, 19, 20, 21, 22 ].each { |day| travel 1.minute; night(Date.new(2026, 10, day), settled: 0) }
    expect(later.reload).to have_attributes(status: "done", detail: hash_including("gave_up_after_nights" => 5))
  end

  it "defers through a halt rather than leaving the deposit as cash" do
    policy!("immediate")
    Allocation::Target.add!(symbol: "DEF", target_percent: "20", user: john)
    deposit(2000)
    inflow = described_class.detect!(account).sole
    travel 1.minute
    SystemSettings.instance.update!(manual_halt: true, manual_halt_reason: "weird day")
    Allocation::DriftJob.perform_now
    expect(inflow.reload).to have_attributes(status: "pending", detail: hash_including("outcomes" => { "DEF" => "not proposed: halted: weird day" }))
  end

  it "ignores a deposit that is not valid or not positive, and leaves one reversed after detection undeployed" do
    policy!("immediate")
    Allocation::Target.add!(symbol: "DEF", target_percent: "20", user: john)
    deposit(2000).update!(status: "CANCELED")
    deposit(-300)
    expect(described_class.detect!(account)).to be_empty
    returned = deposit(1800)
    inflow = described_class.detect!(account).sole
    returned.update!(net_amount: -1800) # the next sync re-signed it
    travel 1.minute
    Allocation::DriftJob.perform_now
    expect(inflow.reload).to have_attributes(status: "done", detail: hash_including("reversed" => true))
    expect(OrderProposal.count).to eq(0)
  end

  it "proposes one tranche per deposit a night, spending what an earlier tranche rolled into it" do
    policy!("ask")
    Allocation::Target.add!(symbol: "DEF", target_percent: "20", user: john)
    deposit(2000)
    inflow = described_class.detect!(account).sole
    inflow.thesis_review.decide!(decision: "stage", weeks: "3", user: john)
    inflow.tranches.update_all(due_on: Date.new(2026, 10, 14)) # three due at once, as after nights the check could not run
    inflow.tranches.first.update!(amount: 50) # under one share: rolls into week 2
    Allocation::DriftJob.perform_now
    expect(inflow.tranches.reload.map(&:status)).to eq(%w[ rolled scheduled scheduled ])
    expect(inflow.tranches.second.amount).to eq(BigDecimal("716.66"))
    expect(AuditEvent.where(kind: "deployment_tranche_status_changed").sole.data).to include("after" => "rolled", "into_week" => 2)
    night(Date.new(2026, 10, 15))
    expect(OrderProposal.where(allocation_source: inflow.tranches.second).sole.quantity).to eq(8) # $716.66 at $86.57
    expect { inflow.thesis_review.reload; inflow.answer!("hold", user: john, reason: "late") }.to raise_error(ActiveRecord::StaleObjectError)
  end
end
