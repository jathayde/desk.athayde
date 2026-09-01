class CreateSystemSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :system_settings do |t|
      t.boolean :shadow_mode, null: false, default: true
      t.boolean :manual_halt, null: false, default: false
      t.text :manual_halt_reason
      t.datetime :manual_halt_at
      t.string :sync_paused_reason

      t.timestamps
      t.check_constraint "id = 1", name: "system_settings_singleton"
    end
  end
end
