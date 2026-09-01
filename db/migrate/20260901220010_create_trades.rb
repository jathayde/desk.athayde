class CreateTrades < ActiveRecord::Migration[8.1]
  def change
    create_table :trades do |t|
      t.references :account, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.references :setup, foreign_key: true
      t.references :order_proposal, foreign_key: true, index: { unique: true }
      t.string :status, null: false, default: "open"
      t.boolean :needs_review, null: false, default: false
      t.boolean :bootstrapped, null: false, default: false
      t.datetime :opened_at
      t.datetime :closed_at
      t.decimal :avg_entry, precision: 18, scale: 4
      t.decimal :avg_exit, precision: 18, scale: 4
      t.decimal :peak_quantity, precision: 18, scale: 6
      t.decimal :planned_stop, precision: 18, scale: 4
      t.decimal :planned_target, precision: 18, scale: 4
      t.decimal :initial_risk, precision: 18, scale: 4
      t.decimal :realized_pnl, precision: 18, scale: 4
      t.decimal :realized_r, precision: 10, scale: 4
      t.text :thesis
      t.text :post_mortem
      t.boolean :followed_setup
      t.datetime :journal_completed_at

      t.timestamps
    end
    add_index :trades, [ :account_id, :instrument_id, :status ]
    add_index :trades, [ :account_id, :instrument_id ], unique: true, where: "status = 'open'", name: "index_trades_one_open_per_instrument"
    add_index :trades, :id, where: "needs_review", name: "index_trades_needing_review"
  end
end
