# What the reconcile job learned, as columns rather than notes in the response jsonb: when it last looked,
# whether that look could see, when an absence was first believed, and which orders made a match ambiguous.
class ReconcileBookkeepingOnSubmissionAttempts < ActiveRecord::Migration[8.1]
  def change
    change_table :submission_attempts do |t|
      t.timestamptz :last_looked_at
      t.boolean :last_look_could_see
      t.timestamptz :first_absence_at
      t.jsonb :ambiguous_order_ids, null: false, default: []
    end
  end
end
