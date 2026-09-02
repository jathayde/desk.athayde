require "rails_helper"

RSpec.describe "Rules" do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }

  before { ready_desk(account, settled: 6000) }

  it "lists the active rules, supersedes on save with a note and mode, and rolls back a bad edit whole" do
    sign_in john
    get risk_rules_path
    expect(response.body).to include("Max risk per trade", "Notional cap", "Save as v2", "rule_#{RiskRule.active_for("notional_cap").id}_params_per_order", "not checked")
    cap = RiskRule.active_for("notional_cap")
    patch risk_rule_path(cap), params: { "rule_#{cap.id}" => { params: { per_order: "1000", per_day: "5000" }, note: "smaller account", mode: "caution" } }
    expect(flash[:notice]).to include("version 2")
    expect(cap.reload).not_to be_active
    expect(RiskRule.active_for("notional_cap")).to have_attributes(version: 2, params: { "per_order" => "1000", "per_day" => "5000" }, note: "smaller account", changed_by: john, mode: "block") # mode is only choosable on wash sale
    expect(AuditEvent.where(kind: "rule_changed").sole.data).to include("before" => { "params" => { "per_order" => "2500", "per_day" => "5000" }, "mode" => "block" })
    wash = RiskRule.active_for("wash_sale")
    patch risk_rule_path(wash), params: { "rule_#{wash.id}" => { params: { days: "30" }, mode: "block" } }
    expect(RiskRule.active_for("wash_sale")).to have_attributes(version: 2, mode: "block")
    positions = RiskRule.active_for("max_positions")
    patch risk_rule_path(positions), params: { "rule_#{positions.id}" => { params: { count: "" } } }
    expect(flash[:alert]).to include("missing count")
    expect(RiskRule.active_for("max_positions")).to have_attributes(id: positions.id, version: 1, active: true)
  end

  it "previews the effect over the waiting proposals the rule governs, without writing" do
    proposal = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :agent)
    breakout = create(:setup, name: "Breakout")
    def_ = create(:instrument, symbol: "DEF", cusip: "594918104")
    Schwab::FakeClient.instance.script_daily_history(symbol: "DEF", close: 50)
    scoped = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "DEF", limit_price: 50, stop_price: 47, thesis: "t", origin: :agent, setup: breakout)
    RiskRule.create!(rule_type: "notional_cap", setup: breakout, params: { "per_order" => "9000", "per_day" => "9000" })
    sign_in john
    cap = RiskRule.active_for("notional_cap")
    get preview_risk_rule_path(cap, "rule_#{cap.id}" => { params: { per_order: "1000", per_day: "5000" } })
    expect(response.body).to include("Preview: Notional cap v2", "XYZ", "pass → <b class=\"warn\">blocks</b>")
    expect(response.body).not_to include("DEF") # the breakout setup has its own row
    expect(cap.reload).to be_active
    expect(AuditEvent.where(kind: "rule_changed")).not_to exist
    expect(proposal.reload).to be_validated
    expect(scoped.reload).to be_validated
  end

  it "locks the editor during a halt unless the approver types why, audited as an override, and keeps the second user out" do
    sign_in john
    SystemSettings.instance.trip_rule_halt!(rule: "daily_loss_halt", reason: "down", resets_at: 1.hour.from_now)
    rule = RiskRule.active_for("daily_loss_halt")
    patch risk_rule_path(rule), params: { "rule_#{rule.id}" => { params: { percent: "5" } } }
    expect(flash[:alert]).to include("locked while a halt")
    expect(rule.reload).to be_active
    patch risk_rule_path(rule), params: { "rule_#{rule.id}" => { params: { percent: "5" }, override_reason: "false halt from a bad percent" } }
    expect(RiskRule.active_for("daily_loss_halt")).to have_attributes(version: 2, note: "override during halt: false halt from a bad percent")
    expect(AuditEvent.where(kind: "rule_changed").sole.data).to include("during_halt" => true, "override_reason" => "false halt from a bad percent")
    delete session_path
    sign_in whitney
    get risk_rules_path
    expect(response).to redirect_to(root_path)
  end
end
