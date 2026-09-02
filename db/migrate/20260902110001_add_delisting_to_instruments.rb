# An operator-marked delisted holding: still synced and journaled, but no longer an unprotected alarm. The
# price at delisting is kept so a stale market value cannot undo the operator on the next sync.
class AddDelistingToInstruments < ActiveRecord::Migration[8.1]
  def change
    add_column :instruments, :delisted_at, :timestamptz
    add_column :instruments, :delisted_price, :decimal, precision: 18, scale: 4
  end
end
