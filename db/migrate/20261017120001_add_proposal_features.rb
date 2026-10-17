# Phase 2.6 step 3 (docs/phase-2.6-plan.md §0.4): what the desk saw when an entry was proposed, frozen with its
# formula version. What a proposal saw when it was made (the reference close, its volatility, the features) is
# written with the row or never, so nothing measured later can be backfilled as if it had been seen; the approval
# quote, written at approval, is frozen once set.
class AddProposalFeatures < ActiveRecord::Migration[8.1]
  FROZEN = <<~SQL # step 2's, restored on the way down
    IF (OLD.reference_close IS NOT NULL AND NEW.reference_close IS DISTINCT FROM OLD.reference_close)
       OR (OLD.reference_on IS NOT NULL AND NEW.reference_on IS DISTINCT FROM OLD.reference_on)
       OR (OLD.quote_at_approval IS NOT NULL AND NEW.quote_at_approval IS DISTINCT FROM OLD.quote_at_approval)
       OR (OLD.reference_volatility IS NOT NULL AND NEW.reference_volatility IS DISTINCT FROM OLD.reference_volatility)%s THEN
      RAISE EXCEPTION 'a proposal''s reference close, features, and approval quote are frozen once set';
    END IF;
    RETURN NEW;
  SQL

  AT_CREATION = <<~SQL
    IF NEW.reference_close IS DISTINCT FROM OLD.reference_close OR NEW.reference_on IS DISTINCT FROM OLD.reference_on
       OR NEW.reference_volatility IS DISTINCT FROM OLD.reference_volatility OR NEW.features IS DISTINCT FROM OLD.features THEN
      RAISE EXCEPTION 'what a proposal saw when it was made is written with it, never after';
    END IF;
    IF OLD.quote_at_approval IS NOT NULL AND NEW.quote_at_approval IS DISTINCT FROM OLD.quote_at_approval THEN
      RAISE EXCEPTION 'a proposal''s approval quote is frozen once set';
    END IF;
    RETURN NEW;
  SQL

  def up
    add_column :order_proposals, :features, :jsonb
    replace_function(AT_CREATION)
  end

  def down
    replace_function(format(FROZEN, "").sub("reference close, features, and", "reference close and"))
    remove_column :order_proposals, :features
  end

  private
    def replace_function(body)
      execute "CREATE OR REPLACE FUNCTION order_proposals_measures_frozen() RETURNS trigger AS $$\nBEGIN\n#{body}END;\n$$ LANGUAGE plpgsql;"
    end
end
