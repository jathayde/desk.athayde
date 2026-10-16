require "rails_helper"

RSpec.describe RiskRule do
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  it "keeps one active global rule per type, even with a null setup, and supersedes instead of editing" do
    rule = described_class.create!(rule_type: "notional_cap", params: { "per_order" => "1000", "per_day" => "3000" })
    expect { described_class.create!(rule_type: "notional_cap", params: { "per_order" => "2000", "per_day" => "3000" }) }.to raise_error(ActiveRecord::RecordNotUnique)
    successor = rule.supersede!(params: { "per_order" => "2000", "per_day" => "3000" }, user: john, note: "raised")
    expect(rule.reload).to have_attributes(active: false, superseded_by: successor)
    expect(successor).to have_attributes(version: 2, active: true, changed_by: john)
    expect(AuditEvent.find_by(kind: "rule_changed").data).to include("before" => { "params" => { "per_order" => "1000", "per_day" => "3000" }, "mode" => "block" }, "after" => { "params" => { "per_order" => "2000", "per_day" => "3000" }, "mode" => "block" }, "during_halt" => false)
    expect { rule.supersede!(params: { "per_order" => "3000", "per_day" => "3000" }, user: john) }.to raise_error(ActiveRecord::StaleObjectError) # already superseded
    SystemSettings.instance.update!(manual_halt: true)
    expect { successor.supersede!(params: { "per_order" => "3000", "per_day" => "3000" }, user: john) }.to raise_error(RiskRule::Locked)
    expect(successor.reload).to be_active
    expect(described_class.new(rule_type: "notional_cap", params: { "per_order" => "1" })).not_to be_valid # a row missing its parameter never reaches the evaluator
    expect(described_class.active_for("notional_cap")).to eq(successor)
  end

  it "prefers a setup's rule over the global one and refuses an unknown type" do
    setup = create(:setup, name: "Breakout")
    global = described_class.create!(rule_type: "stop_collar", params: { "atr_k" => "2.5" })
    specific = described_class.create!(rule_type: "stop_collar", params: { "atr_k" => "3" }, setup: setup)
    expect(described_class.active_for("stop_collar", setup: setup)).to eq(specific)
    expect(described_class.active_for("stop_collar", setup: create(:setup, name: "Other"))).to eq(global)
    expect(described_class.new(rule_type: "vibes", params: {})).not_to be_valid
  end

  it "files book rules under their own scope, resolves them by type, and keeps them out of a proposal's evaluation" do
    band = described_class.create!(rule_type: "rebalance_band", params: { "percent" => "5" }, scope: "trade")
    expect(band).to have_attributes(scope: "book", previewable?: true) # the type decides the scope, whatever the caller says
    expect(described_class.active_for("rebalance_band")).to eq(band)
    expect(described_class.active_set_for(nil)).not_to have_key("rebalance_band")
    expect(described_class.new(rule_type: "correlation_threshold", params: { "value" => "0.6" })).not_to be_valid # window_days missing
    expect(described_class.new(rule_type: "rebalance_band", params: { "percent" => "five" })).not_to be_valid # an unreadable band would stop the nightly check
    expect(described_class.new(rule_type: "rebalance_band", params: { "percent" => "-5" })).not_to be_valid
    expect(described_class.new(rule_type: "rebalance_band", params: { "percent" => "101" })).not_to be_valid
    expect(described_class.new(rule_type: "cash_drag_weeks", params: { "weeks" => "3.0" })).to be_valid
    expect(described_class.new(rule_type: "cash_drag_weeks", params: { "weeks" => "2.5" })).not_to be_valid
    expect(described_class.new(rule_type: "correlation_threshold", params: { "value" => "0.6", "window_days" => "300" })).not_to be_valid
    expect(described_class.create!(rule_type: "cash_drag_weeks", params: { "weeks" => "3" })).not_to be_previewable
    expect { described_class.create!(rule_type: "rebalance_band", params: { "percent" => "4" }) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(Guardrails::Evaluator.new(build(:order_proposal)).call.results.map(&:rule_type)).not_to include(*described_class::BOOK_TYPES)
  end
end
