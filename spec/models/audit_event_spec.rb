require "rails_helper"

RSpec.describe AuditEvent do
  let!(:event) { AuditEvent.log("shadow_mode_toggled", actor: :human, reason: "testing", data: { from: true, to: false }) }

  it "stores the kind, actor, reason, and data" do
    expect(event).to have_attributes(kind: "shadow_mode_toggled", actor: "human", reason: "testing", data: { "from" => true, "to" => false })
  end

  it "only accepts known kinds" do
    expect { AuditEvent.log("made_up", actor: :system) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "refuses updates and destroys in Active Record" do
    expect { event.update!(reason: "changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "refuses updates at the database" do
    expect { AuditEvent.where(id: event.id).update_all(reason: "changed") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "refuses deletes at the database" do
    expect { AuditEvent.where(id: event.id).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "refuses truncate at the database" do
    expect { AuditEvent.connection.truncate("audit_events") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "can point at a subject and a user" do
    user = create(:user)
    logged = AuditEvent.log("re_auth_succeeded", actor: :human, user: user, subject: user)
    expect(logged.subject).to eq(user)
    expect(logged.user).to eq(user)
  end
end
