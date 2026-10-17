# Phase 2.6 step 2 review (docs/phase-2.6-plan.md §0.3): the daily volatility the forecast was made against, the
# standard deviation of the 20 daily log returns up to the reference close, frozen on the proposal and copied to
# each forecast; and the baseline that volatility, the levels, and the horizon imply under the resolver's rules,
# computed once when the forecast is made and frozen with it.
class AddReferenceVolatility < ActiveRecord::Migration[8.1]
  FROZEN = <<~SQL
    IF (OLD.reference_close IS NOT NULL AND NEW.reference_close IS DISTINCT FROM OLD.reference_close)
       OR (OLD.reference_on IS NOT NULL AND NEW.reference_on IS DISTINCT FROM OLD.reference_on)
       OR (OLD.quote_at_approval IS NOT NULL AND NEW.quote_at_approval IS DISTINCT FROM OLD.quote_at_approval)%s THEN
      RAISE EXCEPTION 'a proposal''s reference close and approval quote are frozen once set';
    END IF;
    RETURN NEW;
  SQL

  def up
    add_column :order_proposals, :reference_volatility, :decimal, precision: 9, scale: 6
    add_column :forecasts, :reference_volatility, :decimal, precision: 9, scale: 6 # frozen with the claim: the trigger freezes every column but the result
    add_column :forecasts, :baseline_probability, :decimal, precision: 5, scale: 4
    add_check_constraint :forecasts, "reference_volatility IS NULL OR reference_volatility > 0", name: "forecasts_reference_volatility"
    add_check_constraint :forecasts, "baseline_probability IS NULL OR baseline_probability BETWEEN 0 AND 1", name: "forecasts_baseline_probability"
    replace_function(format(FROZEN, "\n   OR (OLD.reference_volatility IS NOT NULL AND NEW.reference_volatility IS DISTINCT FROM OLD.reference_volatility)"))
  end

  def down
    replace_function(format(FROZEN, ""))
    remove_check_constraint :forecasts, name: "forecasts_baseline_probability"
    remove_check_constraint :forecasts, name: "forecasts_reference_volatility"
    remove_column :forecasts, :baseline_probability
    remove_column :forecasts, :reference_volatility
    remove_column :order_proposals, :reference_volatility
  end

  private
    def replace_function(body)
      execute "CREATE OR REPLACE FUNCTION order_proposals_measures_frozen() RETURNS trigger AS $$\nBEGIN\n#{body}END;\n$$ LANGUAGE plpgsql;"
    end
end
