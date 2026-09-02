RSpec.configure do |config|
  config.before { Agent::FakeAnthropic.instance.reset! }
end
