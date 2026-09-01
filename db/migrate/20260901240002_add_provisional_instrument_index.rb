class AddProvisionalInstrumentIndex < ActiveRecord::Migration[8.1]
  def change
    # Two feeds resolving the same CUSIP-less instrument at once must not both create it.
    add_index :instruments, [ :symbol, :asset_type ], unique: true, where: "cusip IS NULL AND schwab_instrument_id IS NULL", name: "index_instruments_provisional"
  end
end
