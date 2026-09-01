class CreateSubmissionAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :submission_attempts do |t|
      t.references :order_proposal, null: false, foreign_key: true
      t.datetime :attempted_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.jsonb :response, null: false, default: {}
      t.string :outcome, null: false
      t.references :reconciled_order, foreign_key: { to_table: :orders }

      t.timestamps
    end
  end
end
