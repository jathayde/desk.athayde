require "rails_helper"

RSpec.describe "Allocation" do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }

  before do
    create(:balance, account: account, equity: 10_000, as_of: Time.current)
    create(:position, account: account, instrument: xyz, quantity: 40, last_price: 53, market_value: 2120)
    RiskRule.create!(rule_type: "rebalance_band", params: { "percent" => "5" })
  end

  it "adds, reweighs, and retires targets from percents, refusing an unknown symbol and a set past 100 percent" do
    sign_in john
    post allocation_targets_path, params: { symbol: "xyz", target_percent: "15" }
    expect(flash[:notice]).to eq("XYZ targets 15.00%.")
    post allocation_targets_path, params: { asset_class: "Bonds", target_percent: "90" }
    expect(flash[:alert]).to include("105.0%, past 100%")
    post allocation_targets_path, params: { symbol: "NOPE", target_percent: "5" }
    expect(flash[:alert]).to include("NOPE is not known to the desk")
    post allocation_targets_path, params: { symbol: "XYZ", target_percent: "5" }
    expect(flash[:alert]).to include("already has an active target")
    post allocation_targets_path, params: { asset_class: "Bonds", target_percent: "lots" }
    expect(flash[:alert]).to include("Target weight must be greater than 0")
    target = Allocation::Target.sole
    patch allocation_target_path(target), params: { target_percent: "20" }
    expect(target.reload.target_weight).to eq(BigDecimal("0.2"))
    get allocation_targets_path
    expect(response.body).to include("Targets · 20.00% of equity", "not measured yet", "rebalance band rule", "5 points, v1", "Reweigh", "XYZ")
    post allocation_target_retirement_path(target)
    expect(target.reload).not_to be_active
    expect(AuditEvent.where(kind: "allocation_target_changed").count).to eq(3)
  end

  it "authors an instrument's class and tags from the screen, and lets the second user read but not write" do
    sign_in john
    patch instrument_classification_path(xyz), params: { asset_class: "US Equity", tags: %w[ diversifier ] }
    expect(xyz.reload).to have_attributes(asset_class: "us equity", tag_names: [ "diversifier" ])
    delete session_path
    sign_in whitney
    get allocation_targets_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("us equity", "diversifier")
    expect(response.body).not_to include("Add a target", "Reweigh")
    post allocation_targets_path, params: { symbol: "XYZ", target_percent: "10" }
    expect(flash[:alert]).to eq("Only the approver can do that.")
    patch instrument_classification_path(xyz), params: { asset_class: "", tags: [] }
    expect(xyz.reload.asset_class).to eq("us equity")
    expect(Allocation::Target.count).to eq(0)
  end

  it "shows last night's drift rows on the dashboard with the unallocated holdings, never recomputing them" do
    abc = create(:instrument, symbol: "ABC")
    create(:position, account: account, instrument: abc, quantity: 10, last_price: 20, market_value: 200)
    create(:sync_run, feed: "positions", account: account)
    sign_in john
    get root_path
    expect(response.body).to include("No targets.", "Set targets")
    target = Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john)
    target.drifts.create!(as_of: Date.new(2026, 10, 14), weight: BigDecimal("0.212"), target_weight: BigDecimal("0.15"), band: BigDecimal("0.05"), close: 53,
                          drift: BigDecimal("0.062"), notional: BigDecimal("-620"), quantity: 11, action: "reported", detail: { "one_share" => "0.0053" })
    get root_path
    Position.where(instrument: xyz).update_all(market_value: 5000) # the page reads the row, never the book
    Allocation::Target.add!(asset_class: "bonds", target_percent: "10", user: john)
    MarketDay.create!(date: Date.new(2026, 10, 15), trading: true, source: :schwab, fetched_at: Time.current, regular_closes_at: Time.zone.parse("2026-10-15 16:00 EDT"))
    get root_path
    expect(response.body).to include("XYZ · 21.2% of 15.0%", "+6.2 pts", "band 5.0 pts · outside band, sell 11 sh · $620.00", "stale · Wed Oct 14 close", "Unallocated: ABC")
    expect(response.body).to include("bonds · unknown of 10.0%", "not measured yet")
  end

  it "lists book rules and the deployment policy under their own headings, supersedes the policy, and previews the band over stored drift" do
    seed_rule_set
    DeploymentPolicy.create!(mode: "ask")
    RiskRule.create!(rule_type: "cash_drag_weeks", params: { "weeks" => "3" })
    target = Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john)
    target.drifts.create!(as_of: Date.new(2026, 10, 14), weight: BigDecimal("0.212"), target_weight: BigDecimal("0.15"), band: BigDecimal("0.05"), close: 53,
                          drift: BigDecimal("0.062"), action: "reported", detail: { "one_share" => "0.0053" })
    sign_in john
    get risk_rules_path
    expect(response.body).to include("Trade rules · judge one order", "Book rules · judge the whole book", "Rebalance band", "Cash drag weeks", "Now: ask each time.")
    expect(response.body).not_to include(preview_risk_rule_path(RiskRule.active_for("cash_drag_weeks")))
    expect(response.body).not_to include("until Phase 2.5")

    patch deployment_policy_path, params: { deployment_policy: { id: DeploymentPolicy.current.id, mode: "staged", weeks: "6", note: "deposit plan" } }
    expect(flash[:notice]).to eq("Deployment policy is now version 2: staged over 6 weeks.")
    patch deployment_policy_path, params: { deployment_policy: { id: DeploymentPolicy.current.id, mode: "staged", weeks: "" } }
    expect(flash[:alert]).to include("Weeks")
    expect(DeploymentPolicy.current.version).to eq(2)

    band = RiskRule.active_for("rebalance_band")
    get preview_risk_rule_path(band, "rule_#{band.id}" => { params: { percent: "7" } })
    expect(response.body).to include("Preview: Rebalance band v2", "XYZ", "drift +6.2 pts · band 7.0 pts", "outside band (reported) → <b class=\"warn\">within band</b>")
    expect(band.reload).to be_active
    get preview_risk_rule_path(RiskRule.active_for("cash_drag_weeks"))
    expect(flash[:alert]).to include("has no preview")
  end

  it "keeps every write the approver's, refuses a stale policy form, and explains an unreadable band in the preview" do
    seed_rule_set
    policy = DeploymentPolicy.create!(mode: "ask")
    target = Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john)
    sign_in whitney
    patch allocation_target_path(target), params: { target_percent: "30" }
    post allocation_target_retirement_path(target)
    patch deployment_policy_path, params: { deployment_policy: { id: policy.id, mode: "immediate" } }
    band = RiskRule.active_for("rebalance_band")
    get preview_risk_rule_path(band, "rule_#{band.id}" => { params: { percent: "7" } })
    expect(flash[:alert]).to eq("Only the approver can do that.")
    expect([ target.reload.target_weight, target.active, DeploymentPolicy.current ]).to eq([ BigDecimal("0.15"), true, policy ])

    delete session_path
    sign_in john
    patch deployment_policy_path, params: { deployment_policy: { id: policy.id, mode: "immediate" } }
    patch deployment_policy_path, params: { deployment_policy: { id: policy.id, mode: "staged", weeks: "4" } } # the form from before the first save
    expect(flash[:alert]).to include("now version 2. Nothing was saved")
    expect(DeploymentPolicy.current).to have_attributes(mode: "immediate", version: 2)
    post allocation_target_retirement_path(target)
    post allocation_target_retirement_path(target)
    expect(flash[:alert]).to eq("That target was already retired.")
    get preview_risk_rule_path(band, "rule_#{band.id}" => { params: { percent: "five" } })
    expect(response.body).to include("Params percent must be a positive number")
  end

  it "offers Ask again on a standing rejection and clears it, audited" do
    seed_rule_set
    target = Allocation::Target.add!(symbol: xyz.symbol, target_percent: "15", user: john)
    drift = target.drifts.create!(as_of: Date.current - 1, target_weight: target.target_weight, drift: BigDecimal("0.06"), band: BigDecimal("0.05"), close: 53, notional: -600, quantity: 11, action: "proposed")
    proposal = create(:order_proposal, account: account, instrument: xyz, kind: "rebalance", origin: "allocation", side: "sell", quantity: 11, limit_price: 53, allocation_source: drift)
    proposal.reject!(user: john, reason: "not now")
    sign_in john
    get allocation_targets_path
    expect(response.body).to include("Ask again")
    post allocation_target_rejection_clearance_path(target)
    expect(flash[:notice]).to eq("XYZ may be proposed or asked about again at the next check.")
    expect(target.reload.rejection_cleared_at).to be_present
    get allocation_targets_path
    expect(response.body).not_to include("Ask again")
  end
end
