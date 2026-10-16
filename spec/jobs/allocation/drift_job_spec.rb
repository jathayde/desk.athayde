require "rails_helper"

RSpec.describe Allocation::DriftJob do
  let(:closed_at) { Time.find_zone!("America/New_York").local(2026, 10, 14, 16) } # a Wednesday
  let!(:token) { create(:schwab_token) }
  let!(:account) { create(:account) }
  let(:xyz) { create(:instrument, symbol: "XYZ") }
  let(:def_) { create(:instrument, symbol: "DEF") }
  let(:bnd) { create(:instrument, symbol: "BND", asset_class: "Bonds") }
  let(:abc) { create(:instrument, symbol: "ABC") }
  let(:john) { create(:user, approver: true) }

  around { |example| travel_to(closed_at + 70.minutes) { example.run } }

  before do
    RiskRule.create!(rule_type: "rebalance_band", params: { "percent" => "5" })
    create(:balance, account: account, equity: 10_000, as_of: closed_at + 45.minutes)
    create(:sync_run, feed: "positions", account: account, started_at: closed_at + 50.minutes, finished_at: closed_at + 50.minutes)
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 53, market_value: 2120)
    create(:position, account: account, instrument: bnd, quantity: 20, last_price: 75, market_value: 1500)
    create(:position, account: account, instrument: abc, quantity: 10, last_price: 20, market_value: 200)
  end

  def drift_for(target) = target.drifts.find_by!(as_of: closed_at.to_date)

  it "writes one row per active target from the post-close book: held, unheld by quote, and a class by its members" do
    held = Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john)
    unheld = Allocation::Target.add!(symbol: def_.symbol, target_percent: "10", user: john)
    bonds = Allocation::Target.add!(asset_class: "bonds", target_percent: "18", user: john)
    Allocation::Target.add!(symbol: abc.symbol, target_percent: "2", user: john).retire!(user: john)

    described_class.perform_now

    expect(drift_for(held)).to have_attributes(weight: BigDecimal("0.212"), target_weight: BigDecimal("0.15"), drift: BigDecimal("0.062"), band: BigDecimal("0.05"),
                                               close: 53, notional: BigDecimal("-620"), quantity: 11, action: "reported")
    expect(drift_for(held).detail).to eq("one_share" => "0.0053")
    expect(drift_for(unheld)).to have_attributes(weight: 0, close: BigDecimal("86.57"), notional: 1000, quantity: 11, action: "reported") # DEF's fixture lastPrice
    expect(drift_for(bonds)).to have_attributes(weight: BigDecimal("0.15"), drift: BigDecimal("-0.03"), band: BigDecimal("0.05"), close: nil, quantity: nil, action: "none")
    expect(drift_for(bonds).detail).to eq("members" => [ "BND" ])
    expect(Allocation::Drift.count).to eq(3) # the retired target is not measured
    expect(AuditEvent.where(kind: "allocation_drift_recorded").count).to eq(3)
    expect(AuditEvent.where(kind: "allocation_drift_checked").sole.data).to include("as_of" => "2026-10-14", "actions" => { "reported" => 2, "none" => 1 })
    expect(OrderProposal.count).to eq(0) # step 1 reports; nothing proposes
    expect(Allocation::Book.unallocated(account).map { |p| p.instrument.symbol }).to eq([ "ABC" ])
  end

  it "widens an instrument's band to one share when a share is the bigger slice of equity" do
    big = create(:instrument, symbol: "BIG")
    create(:position, account: account, instrument: big, quantity: 1, last_price: 900, market_value: 900)
    target = Allocation::Target.add!(symbol: big.symbol, target_percent: "3", user: john)
    described_class.perform_now
    expect(drift_for(target)).to have_attributes(drift: BigDecimal("0.06"), band: BigDecimal("0.09"), action: "none")
  end

  describe "an unavailable run marks every target with the same reasons and measures nothing" do
    let!(:held) { Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john) }
    let!(:unheld) { Allocation::Target.add!(symbol: def_.symbol, target_percent: "10", user: john) }

    def reasons_after_run
      described_class.perform_now
      expect([ drift_for(held), drift_for(unheld) ].map(&:action)).to eq(%w[ unavailable unavailable ])
      expect(drift_for(held)).to have_attributes(weight: nil, drift: nil, notional: nil, quantity: nil)
      expect(AuditEvent.where(kind: "allocation_drift_recorded").count).to eq(2)
      drift_for(unheld).detail["reasons"]
    end

    it("when the positions sync began before the close") { SyncRun.update_all(started_at: closed_at - 2.minutes); expect(reasons_after_run).to eq([ "positions not synced since the close" ]) }
    it("when the positions sync since the close was partial") { SyncRun.update_all(status: "partial"); expect(reasons_after_run).to eq([ "positions sync since the close partial" ]) }
    it("when the balance predates the close") { Balance.update_all(as_of: closed_at - 1.minute); expect(reasons_after_run).to eq([ "balance not synced since the close" ]) }
    it("when a held price is zero") { Position.where(instrument: xyz).update_all(last_price: 0); expect(reasons_after_run).to eq([ "XYZ unpriced" ]) }
    it("when a covered instrument is delisted") { xyz.delist!(user: john); expect(reasons_after_run).to eq([ "XYZ delisted" ]) }
    it("when the band rule is gone") { RiskRule.update_all(active: false); expect(reasons_after_run).to eq([ "no rebalance_band rule" ]) }

    it "when the quote fetch fails, naming the failure once rather than each symbol" do
      Schwab::FakeClient.instance.enqueue(:quotes) { raise Schwab::ServerError, "quotes down" }
      expect(reasons_after_run.sole).to start_with("quotes unavailable")
    end
  end

  it "keeps a measured row when a same-day rerun cannot measure, recording why on the run" do
    target = Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john)
    described_class.perform_now
    Position.where(instrument: xyz).update_all(last_price: nil)
    described_class.perform_now
    expect(drift_for(target)).to have_attributes(action: "reported", drift: BigDecimal("0.062"))
    expect(AuditEvent.where(kind: "allocation_drift_checked").order(:id).last.data).to include("reasons" => [ "XYZ unpriced" ], "actions" => {})
  end

  it "judges a class by the held members without a target of their own" do
    tlt = create(:instrument, symbol: "TLT", asset_class: "bonds")
    create(:position, account: account, instrument: tlt, quantity: 10, last_price: 90, market_value: 900)
    Allocation::Target.add!(symbol: tlt.symbol, target_percent: "9", user: john)
    bonds = Allocation::Target.add!(asset_class: "bonds", target_percent: "15", user: john)
    described_class.perform_now
    expect(drift_for(bonds)).to have_attributes(weight: BigDecimal("0.15"), action: "none")
    expect(drift_for(bonds).detail["members"]).to eq([ "BND" ])
  end

  it "measures today only, and only on Schwab's calendar" do
    Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john)
    described_class.perform_now(closed_at.to_date - 1)
    expect(Allocation::Drift.count).to eq(0) # a past day would carry today's numbers
    Schwab::FakeClient.instance.enqueue(:market_hours) { raise Schwab::ServerError, "hours down" }
    described_class.perform_now
    expect(MarketDay.find_by!(date: closed_at.to_date)).to be_fallback
    expect(Allocation::Drift.count).to eq(0)
  end

  it "keeps a row that already proposed and does nothing on a closed day or without targets" do
    target = Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john)
    proposal = create(:order_proposal, account: account, instrument: xyz)
    target.drifts.create!(as_of: closed_at.to_date, target_weight: target.target_weight, action: "proposed", order_proposal: proposal, drift: BigDecimal("0.07"))
    described_class.perform_now
    expect(drift_for(target)).to have_attributes(action: "proposed", drift: BigDecimal("0.07"))

    Schwab::FakeClient.instance.close_market_on(closed_at.to_date + 1)
    described_class.perform_now(closed_at.to_date + 1)
    expect(Allocation::Drift.where(as_of: closed_at.to_date + 1)).to be_empty

    target.retire!(user: john)
    expect { described_class.perform_now }.not_to change(AuditEvent.where(kind: "allocation_drift_checked"), :count)
  end
end
