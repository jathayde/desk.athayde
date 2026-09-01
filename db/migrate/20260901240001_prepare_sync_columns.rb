class PrepareSyncColumns < ActiveRecord::Migration[8.1]
  def change
    # Cursors are per account and feed; gap_from marks history Schwab can no longer return.
    add_reference :sync_runs, :account, foreign_key: true
    add_column :sync_runs, :gap_from, :datetime

    # Container strategies (OCO, TRIGGER parents) have no leg and therefore no instrument.
    change_column_null :orders, :instrument_id, true
    add_column :orders, :remaining_quantity, :decimal, precision: 18, scale: 6
    add_column :orders, :strategy_type, :string
    add_index :orders, [ :account_id, :instrument_id, :entered_at ]

    # Only VALID activities are journaled; the rest are kept for the record.
    add_column :activities, :status, :string
  end
end
