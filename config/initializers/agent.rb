# The scheduled runtime's model client: real in production, scripted everywhere else unless asked otherwise.
adapter = ENV.fetch("ANTHROPIC_ADAPTER") { Rails.env.production? ? "http" : "fake" }.to_sym
raise "ANTHROPIC_ADAPTER=fake is not allowed in production" if Rails.env.production? && adapter == :fake
Rails.application.config.x.agent.adapter = adapter
Rails.application.config.x.memory.repo_path = ENV["MEMORY_REPO_PATH"].presence
