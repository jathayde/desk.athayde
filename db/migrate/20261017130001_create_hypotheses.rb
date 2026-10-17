# Phase 2.6 step 4 (docs/phase-2.6-plan.md §0.5, §0.6): hypotheses written before the evidence, every variant a row,
# the claim frozen by the database, the holdout never backdated; the verdict frozen into evidence at the decision;
# and the proposal that names one, named when it is made or never.
class CreateHypotheses < ActiveRecord::Migration[8.1]
  DECISION = %w[ status evidence decided_at decided_by_id decision_note tested_at tested_by_id updated_at ].freeze
  PROPOSAL_AT_CREATION = <<~SQL
    IF NEW.reference_close IS DISTINCT FROM OLD.reference_close OR NEW.reference_on IS DISTINCT FROM OLD.reference_on
       OR NEW.reference_volatility IS DISTINCT FROM OLD.reference_volatility OR NEW.features IS DISTINCT FROM OLD.features%s THEN
      RAISE EXCEPTION 'what a proposal saw when it was made is written with it, never after';
    END IF;
    IF OLD.quote_at_approval IS NOT NULL AND NEW.quote_at_approval IS DISTINCT FROM OLD.quote_at_approval THEN
      RAISE EXCEPTION 'a proposal''s approval quote is frozen once set';
    END IF;
    RETURN NEW;
  SQL

  def up
    create_table :hypotheses do |t|
      t.text :statement, null: false
      t.references :setup, foreign_key: true
      t.text :rules, null: false
      t.integer :min_sample, null: false
      t.date :holdout_from, null: false
      t.decimal :expected_mean_r, precision: 10, scale: 4, null: false
      t.references :parent, foreign_key: { to_table: :hypotheses }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "proposed"
      t.timestamptz :tested_at
      t.references :tested_by, foreign_key: { to_table: :users }
      t.jsonb :evidence
      t.timestamptz :decided_at
      t.references :decided_by, foreign_key: { to_table: :users }
      t.text :decision_note
      t.timestamps
    end
    add_check_constraint :hypotheses, "status IN ('proposed', 'testing', 'accepted', 'rejected', 'retired')", name: "hypotheses_status"
    add_check_constraint :hypotheses, "min_sample BETWEEN 10 AND 500", name: "hypotheses_min_sample"
    add_check_constraint :hypotheses, "holdout_from >= (created_at AT TIME ZONE 'America/New_York')::date", name: "hypotheses_holdout_not_backdated"
    add_check_constraint :hypotheses, "status <> 'proposed' OR tested_at IS NULL", name: "hypotheses_untested_while_proposed"
    add_check_constraint :hypotheses, "status IN ('proposed', 'retired') OR tested_at IS NOT NULL", name: "hypotheses_tested_once_testing"

    add_reference :order_proposals, :hypothesis, foreign_key: true

    decision = DECISION.map { |column| "'#{column}'" }.join(", ")
    execute <<~SQL
      CREATE FUNCTION hypotheses_frozen() RETURNS trigger AS $$
      BEGIN
        IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
          RAISE EXCEPTION 'hypotheses are never deleted';
        END IF;
        IF (to_jsonb(NEW) - ARRAY[#{decision}]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[#{decision}]) THEN
          RAISE EXCEPTION 'a hypothesis is never edited: write a variant';
        END IF;
        IF (OLD.evidence IS NOT NULL AND NEW.evidence IS DISTINCT FROM OLD.evidence)
           OR (OLD.tested_at IS NOT NULL AND NEW.tested_at IS DISTINCT FROM OLD.tested_at)
           OR (OLD.tested_by_id IS NOT NULL AND NEW.tested_by_id IS DISTINCT FROM OLD.tested_by_id)
           OR (OLD.decided_at IS NOT NULL AND NEW.decided_at IS DISTINCT FROM OLD.decided_at)
           OR (OLD.decided_by_id IS NOT NULL AND NEW.decided_by_id IS DISTINCT FROM OLD.decided_by_id)
           OR (OLD.decision_note IS NOT NULL AND NEW.decision_note IS DISTINCT FROM OLD.decision_note) THEN
          RAISE EXCEPTION 'a hypothesis''s testing, verdict, and decision are frozen once made';
        END IF;
        IF NEW.status IS DISTINCT FROM OLD.status AND (OLD.status, NEW.status) NOT IN
           (('proposed', 'testing'), ('proposed', 'retired'), ('testing', 'accepted'), ('testing', 'rejected'), ('testing', 'retired'), ('accepted', 'retired'), ('rejected', 'retired')) THEN
          RAISE EXCEPTION 'a hypothesis cannot go from % to %', OLD.status, NEW.status;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER hypotheses_frozen BEFORE UPDATE OR DELETE ON hypotheses FOR EACH ROW EXECUTE FUNCTION hypotheses_frozen();
      CREATE TRIGGER hypotheses_no_truncate BEFORE TRUNCATE ON hypotheses FOR EACH STATEMENT EXECUTE FUNCTION hypotheses_frozen();
    SQL
    replace_proposal_function(format(PROPOSAL_AT_CREATION, " OR NEW.hypothesis_id IS DISTINCT FROM OLD.hypothesis_id"))
  end

  def down
    replace_proposal_function(format(PROPOSAL_AT_CREATION, ""))
    execute "DROP TRIGGER hypotheses_no_truncate ON hypotheses; DROP TRIGGER hypotheses_frozen ON hypotheses; DROP FUNCTION hypotheses_frozen();"
    remove_reference :order_proposals, :hypothesis, foreign_key: true
    drop_table :hypotheses
  end

  private
    def replace_proposal_function(body)
      execute "CREATE OR REPLACE FUNCTION order_proposals_measures_frozen() RETURNS trigger AS $$\nBEGIN\n#{body}END;\n$$ LANGUAGE plpgsql;"
    end
end
