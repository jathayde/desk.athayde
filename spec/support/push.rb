RSpec.configure do |config|
  config.before { Push::FakeApns.instance.reset! }
end
