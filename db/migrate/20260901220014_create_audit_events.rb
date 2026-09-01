class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :audit_events do |t|
      t.string :kind, null: false
      t.string :actor, null: false
      t.references :user, foreign_key: true
      t.references :subject, polymorphic: true
      t.jsonb :data, null: false, default: {}
      t.text :reason
      t.datetime :created_at, null: false
    end
    add_index :audit_events, :kind
    add_index :audit_events, :created_at

    execute <<~SQL
      CREATE FUNCTION audit_events_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'audit_events is append-only';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER audit_events_append_only
        BEFORE UPDATE OR DELETE ON audit_events
        FOR EACH ROW EXECUTE FUNCTION audit_events_append_only();

      CREATE TRIGGER audit_events_no_truncate
        BEFORE TRUNCATE ON audit_events
        FOR EACH STATEMENT EXECUTE FUNCTION audit_events_append_only();
    SQL
  end

  def down
    execute "DROP TRIGGER audit_events_no_truncate ON audit_events; DROP TRIGGER audit_events_append_only ON audit_events; DROP FUNCTION audit_events_append_only();"
    drop_table :audit_events
  end
end
