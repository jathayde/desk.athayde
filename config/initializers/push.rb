# APNs delivery: real in production, scripted everywhere else unless asked otherwise. The key, key id, team
# id, and bundle id live in credentials under apns (docs/phase-2-plan.md §10); a production desk without
# them boots and simply sends no pushes, since the shell may not exist yet.
adapter = ENV.fetch("PUSH_ADAPTER") { Rails.env.production? ? "http" : "fake" }.to_sym
raise "PUSH_ADAPTER=fake is not allowed in production" if Rails.env.production? && adapter == :fake
Rails.application.config.x.push.adapter = adapter
