# Two tabs, or the tool and the form, cannot both propose the same thing: one undecided proposal per account,
# instrument, and side, refused in words by Proposals::Create and by this index.
class OneOpenProposalPerInstrumentAndSide < ActiveRecord::Migration[8.1]
  def change
    add_index :order_proposals, [ :account_id, :instrument_id, :side ], unique: true, where: "status IN ('proposed', 'validated')", name: "index_order_proposals_one_open_per_instrument_and_side"
  end
end
