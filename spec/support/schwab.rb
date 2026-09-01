module SchwabFixtures
  def schwab_fixture(name) = JSON.parse(Rails.root.join("lib/schwab_fixtures/#{name}.json").read)
end

RSpec.configure do |config|
  config.include SchwabFixtures
  # Both are process-wide state; every example starts clean.
  config.before do
    Rails.cache.clear
    Schwab::FakeClient.instance.reset!
    # Real app credentials live only in the production file; the suite never needs real ones.
    allow(Schwab).to receive_messages(app_key: "test-app-key", app_secret: "test-app-secret")
  end
end
