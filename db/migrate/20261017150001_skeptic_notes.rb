# Phase 2.6 step 6 (docs/phase-2.6-plan.md §0.9): the skeptic, an agent run per entry proposal rather than per day,
# and the note it writes, frozen on the proposal once written.
class SkepticNotes < ActiveRecord::Migration[8.1]
  def up
    add_reference :agent_runs, :order_proposal, foreign_key: true, index: false
    add_index :agent_runs, :order_proposal_id, unique: true, where: "kind = 'skeptic' AND status <> 'failed'", name: "index_agent_runs_one_skeptic_per_proposal"
    remove_index :agent_runs, name: "index_agent_runs_one_per_kind_and_day"
    add_index :agent_runs, [ :kind, :market_date ], unique: true, where: "status <> 'failed' AND kind <> 'skeptic'", name: "index_agent_runs_one_per_kind_and_day"
    add_check_constraint :agent_runs, "(kind = 'skeptic') = (order_proposal_id IS NOT NULL)", name: "agent_runs_skeptic_has_a_proposal"

    change_table :order_proposals, bulk: true do |t|
      t.text :skeptic_note
      t.string :skeptic_risk
      t.references :skeptic_run, foreign_key: { to_table: :agent_runs }, index: false
    end
    add_check_constraint :order_proposals, "skeptic_risk IS NULL OR skeptic_risk IN ('thesis', 'timing', 'sample', 'cost', 'trend', 'other')", name: "order_proposals_skeptic_risk"
    add_check_constraint :order_proposals, "skeptic_note IS NULL OR (skeptic_note <> '' AND skeptic_risk IS NOT NULL AND skeptic_run_id IS NOT NULL)", name: "order_proposals_skeptic_note_whole"
    execute <<~SQL
      CREATE FUNCTION order_proposals_skeptic_frozen() RETURNS trigger AS $$
      BEGIN
        IF (OLD.skeptic_note IS NOT NULL AND NEW.skeptic_note IS DISTINCT FROM OLD.skeptic_note)
           OR (OLD.skeptic_risk IS NOT NULL AND NEW.skeptic_risk IS DISTINCT FROM OLD.skeptic_risk)
           OR (OLD.skeptic_run_id IS NOT NULL AND NEW.skeptic_run_id IS DISTINCT FROM OLD.skeptic_run_id) THEN
          RAISE EXCEPTION 'a skeptic note is frozen once written';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER order_proposals_skeptic_frozen BEFORE UPDATE ON order_proposals FOR EACH ROW EXECUTE FUNCTION order_proposals_skeptic_frozen();
    SQL
  end

  def down
    execute "DROP TRIGGER order_proposals_skeptic_frozen ON order_proposals; DROP FUNCTION order_proposals_skeptic_frozen();"
    remove_check_constraint :order_proposals, name: "order_proposals_skeptic_note_whole"
    remove_check_constraint :order_proposals, name: "order_proposals_skeptic_risk"
    change_table(:order_proposals, bulk: true) { |t| t.remove_references :skeptic_run, foreign_key: { to_table: :agent_runs }, index: false; t.remove :skeptic_note, :skeptic_risk }
    remove_check_constraint :agent_runs, name: "agent_runs_skeptic_has_a_proposal"
    execute "DELETE FROM tool_calls WHERE agent_run_id IN (SELECT id FROM agent_runs WHERE kind = 'skeptic'); DELETE FROM agent_runs WHERE kind = 'skeptic';" # one a day again: the per-proposal runs cannot stay"
    remove_index :agent_runs, name: "index_agent_runs_one_per_kind_and_day"
    add_index :agent_runs, [ :kind, :market_date ], unique: true, where: "status <> 'failed'", name: "index_agent_runs_one_per_kind_and_day"
    remove_index :agent_runs, name: "index_agent_runs_one_skeptic_per_proposal"
    remove_reference :agent_runs, :order_proposal, foreign_key: true, index: false
  end
end
