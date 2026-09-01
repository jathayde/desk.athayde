# Every datetime column is timestamptz, so raw SQL, psql, and Rails agree on the instant.
ActiveSupport.on_load(:active_record_postgresqladapter) { self.datetime_type = :timestamptz }
