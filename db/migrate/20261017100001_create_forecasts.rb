# Phase 2.6 step 1 (docs/phase-2.6-plan.md §0.1, §0.2, §0.8): forecasts, one per author per entry proposal, frozen by
# the database once written, the resolver the only writer of the outcome and only while it is open; the last final
# close an entry was drafted against, which every forecast on it is measured from; and the quote an approval saw,
# both frozen once set. The freeze is on the whole row less the result columns, so a column added later is frozen
# by default.
class CreateForecasts < ActiveRecord::Migration[8.1]
  RESULT = %w[ outcome void_reason resolved_at detail checked_through updated_at ].freeze

  def up
    change_table :order_proposals, bulk: true do |t|
      t.decimal :reference_close, precision: 18, scale: 4
      t.date :reference_on
      t.jsonb :quote_at_approval
    end

    create_table :forecasts do |t|
      t.references :order_proposal, null: false, foreign_key: true, index: false
      t.string :author, null: false
      t.references :user, foreign_key: true
      t.decimal :probability, precision: 5, scale: 4, null: false
      t.integer :horizon_days, null: false
      t.decimal :entry_price, precision: 18, scale: 4, null: false
      t.decimal :target_price, precision: 18, scale: 4, null: false
      t.decimal :stop_price, precision: 18, scale: 4, null: false
      t.decimal :reference_close, precision: 18, scale: 4, null: false
      t.date :reference_on, null: false
      t.date :starts_on, null: false # the first session whose candle can count: none that includes range from before made_at
      t.timestamptz :made_at, null: false, default: -> { "now()" }
      t.boolean :saw_agent_forecast, null: false, default: false
      t.date :checked_through
      t.string :outcome
      t.string :void_reason
      t.timestamptz :resolved_at
      t.jsonb :detail, null: false, default: {}
      t.timestamps
    end
    add_index :forecasts, [ :order_proposal_id, :author ], unique: true
    add_index :forecasts, :order_proposal_id, where: "outcome IS NULL", name: "index_forecasts_open"
    add_check_constraint :forecasts, "author IN ('agent', 'human')", name: "forecasts_author"
    add_check_constraint :forecasts, "probability > 0 AND probability < 1", name: "forecasts_probability"
    add_check_constraint :forecasts, "horizon_days BETWEEN 1 AND 60", name: "forecasts_horizon"
    add_check_constraint :forecasts, "stop_price > 0 AND stop_price < entry_price AND stop_price < reference_close AND reference_close < target_price AND entry_price < target_price", name: "forecasts_levels"
    add_check_constraint :forecasts, "outcome IS NULL OR outcome IN ('hit', 'miss', 'void')", name: "forecasts_outcome"
    add_check_constraint :forecasts, "(outcome IS NOT DISTINCT FROM 'void') = (void_reason IS NOT NULL) AND (outcome IS NULL) = (resolved_at IS NULL)", name: "forecasts_resolution"
    add_check_constraint :forecasts, "void_reason IS NULL OR void_reason IN ('never_entered', 'split', 'data_unavailable')", name: "forecasts_void_reason"

    result = RESULT.map { |column| "'#{column}'" }.join(", ")
    execute <<~SQL
      CREATE FUNCTION forecasts_frozen() RETURNS trigger AS $$
      BEGIN
        IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
          RAISE EXCEPTION 'forecasts are never deleted';
        END IF;
        IF (to_jsonb(NEW) - ARRAY[#{result}]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[#{result}]) THEN
          RAISE EXCEPTION 'a forecast''s claim is frozen';
        END IF;
        IF OLD.outcome IS NOT NULL AND (to_jsonb(NEW) - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at') THEN
          RAISE EXCEPTION 'a resolved forecast is frozen';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER forecasts_frozen BEFORE UPDATE OR DELETE ON forecasts FOR EACH ROW EXECUTE FUNCTION forecasts_frozen();
      CREATE TRIGGER forecasts_no_truncate BEFORE TRUNCATE ON forecasts FOR EACH STATEMENT EXECUTE FUNCTION forecasts_frozen();

      CREATE FUNCTION order_proposals_measures_frozen() RETURNS trigger AS $$
      BEGIN
        IF (OLD.reference_close IS NOT NULL AND NEW.reference_close IS DISTINCT FROM OLD.reference_close)
           OR (OLD.reference_on IS NOT NULL AND NEW.reference_on IS DISTINCT FROM OLD.reference_on)
           OR (OLD.quote_at_approval IS NOT NULL AND NEW.quote_at_approval IS DISTINCT FROM OLD.quote_at_approval) THEN
          RAISE EXCEPTION 'a proposal''s reference close and approval quote are frozen once set';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER order_proposals_measures_frozen BEFORE UPDATE ON order_proposals FOR EACH ROW EXECUTE FUNCTION order_proposals_measures_frozen();
    SQL
  end

  def down
    execute "DROP TRIGGER order_proposals_measures_frozen ON order_proposals; DROP FUNCTION order_proposals_measures_frozen();"
    execute "DROP TRIGGER forecasts_no_truncate ON forecasts; DROP TRIGGER forecasts_frozen ON forecasts; DROP FUNCTION forecasts_frozen();"
    drop_table :forecasts
    change_table(:order_proposals, bulk: true) { |t| t.remove :reference_close, :reference_on, :quote_at_approval }
  end
end
