# Phase 2.5 step 2: a proposal names the allocation row it came from, once per side, and a target remembers
# when the operator cleared a standing rejection. See docs/phase-2.5-plan.md §0.5-0.6 and §1.
class RebalanceProposals < ActiveRecord::Migration[8.1]
  def change
    add_reference :order_proposals, :allocation_source, polymorphic: true, index: false
    add_index :order_proposals, [ :account_id, :instrument_id, :side, :allocation_source_type, :allocation_source_id ], unique: true,
              where: "allocation_source_id IS NOT NULL", name: "index_order_proposals_one_per_allocation_source"
    add_column :allocation_targets, :rejection_cleared_at, :timestamptz
  end
end
