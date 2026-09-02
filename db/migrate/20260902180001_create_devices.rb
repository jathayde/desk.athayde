# The phone that will receive pushes (docs/phase-2-plan.md §10): one row per push token, owned by the user who
# registered it. Delivery waits on the APNs gem decision; registration does not.
class CreateDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :devices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :platform, null: false
      t.string :token, null: false
      t.string :app_version
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    add_index :devices, :token, unique: true
  end
end
