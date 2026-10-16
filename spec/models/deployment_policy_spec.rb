require "rails_helper"

RSpec.describe DeploymentPolicy do
  let(:john) { create(:user, approver: true) }

  it "supersedes like a rule: one active row, the next version, one audit row, locked during a halt without a reason" do
    policy = described_class.create!(mode: "ask")
    expect { described_class.create!(mode: "immediate") }.to raise_error(ActiveRecord::RecordNotUnique)
    staged = policy.supersede!(mode: "staged", weeks: "4", user: john, note: "after the deposit talk")
    expect(policy.reload).to have_attributes(active: false, superseded_by: staged)
    expect(described_class.current).to have_attributes(mode: "staged", weeks: 4, version: 2, changed_by: john, summary: "staged over 4 weeks")
    expect(AuditEvent.where(kind: "deployment_policy_changed").sole.data).to include("before" => { "mode" => "ask", "weeks" => nil }, "after" => { "mode" => "staged", "weeks" => 4 }, "version" => 2)
    expect { policy.supersede!(mode: "immediate", weeks: nil, user: john) }.to raise_error(ActiveRecord::StaleObjectError)

    SystemSettings.instance.update!(manual_halt: true)
    expect { staged.supersede!(mode: "immediate", weeks: nil, user: john) }.to raise_error(Superseding::Locked)
    immediate = staged.supersede!(mode: "immediate", weeks: "4", user: john, override_reason: "wrong policy")
    expect(immediate).to have_attributes(weeks: nil, note: "override during halt: wrong policy") # weeks only mean something when staged
  end

  it "refuses a staged policy without weeks and an unknown mode, leaving the active row in place" do
    policy = described_class.create!(mode: "ask")
    expect { policy.supersede!(mode: "staged", weeks: "", user: john) }.to raise_error(ActiveRecord::RecordInvalid, /Weeks/)
    expect { policy.supersede!(mode: "yolo", weeks: nil, user: john) }.to raise_error(ActiveRecord::RecordInvalid, /Mode/)
    expect(described_class.current).to eq(policy)
  end
end
