require "rails_helper"

RSpec.describe SystemSettings do
  it "creates the single row on first access with shadow mode on and no halt" do
    settings = SystemSettings.instance
    expect(settings).to have_attributes(id: 1, shadow_mode: true, manual_halt: false)
    expect(SystemSettings.instance).to eq(settings)
  end

  it "cannot hold a second row" do
    SystemSettings.instance
    expect { SystemSettings.create!(id: 2) }.to raise_error(ActiveRecord::StatementInvalid, /system_settings_singleton/)
  end

  describe "halts" do
    let(:settings) { described_class.instance }

    it "blocks entries but not exits on a rule halt, everything on the kill switch, and clears on reset or by hand" do
      expect(settings).to be_entries_allowed.and be_exits_allowed
      settings.trip_rule_halt!(rule: "daily_loss_halt", reason: "down 3.2% today", resets_at: 1.day.from_now)
      settings.trip_rule_halt!(rule: "daily_loss_halt", reason: "still down", resets_at: 12.hours.from_now) # an earlier reset: nothing
      settings.trip_rule_halt!(rule: "max_drawdown_halt", reason: "down 12% from the high", resets_at: 3.days.from_now) # a later reset extends, on the record
      expect(settings).to be_rule_halted
      expect(settings).not_to be_entries_allowed
      expect(settings).to be_exits_allowed
      expect(settings.rule_halt_rule).to eq("max_drawdown_halt")
      expect(AuditEvent.where(kind: "rule_halt_tripped").count).to eq(2)
      expect(AuditEvent.where(kind: "rule_halt_tripped").last.data).to include("extended" => true, "rule" => "max_drawdown_halt")
      settings.trip_rule_halt!(rule: "max_drawdown_halt", reason: "worse", resets_at: nil) # indefinite: later than any time
      expect(settings.rule_halt_resets_at).to be_nil
      settings.trip_rule_halt!(rule: "daily_loss_halt", reason: "down again", resets_at: 1.day.from_now) # cannot shorten an indefinite halt
      expect(settings.rule_halt_resets_at).to be_nil
      expect(settings.rule_halt_rule).to eq("max_drawdown_halt")
      settings.clear_rule_halt!(reason: "test")
      settings.trip_rule_halt!(rule: "daily_loss_halt", reason: "down", resets_at: 3.days.from_now)

      travel 2.days
      expect(settings).to be_rule_halted # the later reset holds
      travel 2.days
      expect(settings).not_to be_rule_halted
      settings.sweep_rule_halt!
      expect(AuditEvent.where(kind: "rule_halt_cleared").last).to have_attributes(actor: "system", reason: "reset time passed")
      settings.trip_rule_halt!(rule: "daily_loss_halt", reason: "again", resets_at: 1.day.from_now)
      settings.clear_rule_halt!(user: create(:user, email_address: "john@athayde.com"), reason: "reviewed")
      expect(settings.rule_halt_rule).to be_nil
      expect(AuditEvent.where(kind: "rule_halt_cleared").last.actor).to eq("human")

      settings.update!(manual_halt: true)
      expect(settings).not_to be_entries_allowed
      expect(settings).not_to be_exits_allowed
    end
  end
end
