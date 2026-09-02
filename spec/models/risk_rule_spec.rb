require "rails_helper"

RSpec.describe RiskRule do
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  it "keeps one active global rule per type, even with a null setup, and supersedes instead of editing" do
    rule = described_class.create!(rule_type: "notional_cap", params: { "per_order" => "1000" })
    expect { described_class.create!(rule_type: "notional_cap", params: { "per_order" => "2000" }) }.to raise_error(ActiveRecord::RecordNotUnique)
    successor = rule.supersede!(params: { "per_order" => "2000" }, user: john, note: "raised")
    expect(rule.reload).to have_attributes(active: false, superseded_by: successor)
    expect(successor).to have_attributes(version: 2, active: true, changed_by: john)
    expect(AuditEvent.find_by(kind: "rule_changed").data).to include("before" => { "per_order" => "1000" }, "after" => { "per_order" => "2000" })
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
end
