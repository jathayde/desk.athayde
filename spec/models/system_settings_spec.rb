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
end
