# The fake adapter backs development seeds, the test suite, and Playwright. Production talks to Schwab.
adapter = ENV.fetch("SCHWAB_ADAPTER") { Rails.env.production? ? "http" : "fake" }.to_sym
raise "SCHWAB_ADAPTER=fake is not allowed in production" if Rails.env.production? && adapter == :fake
Rails.application.config.x.schwab.adapter = adapter
