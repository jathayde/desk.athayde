# Run using bin/ci. Each step runs only while everything before it is green.
CI.run do
  step "Setup", "bin/setup --skip-server"
  step "Style: Ruby", "bin/rubocop" if success?
  step "Tests: RSpec", "bin/rspec" if success?
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant" if success?
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error" if success?
  step "Security: Importmap vulnerability audit", "bin/importmap audit" if success?
  step "Security: Gem audit", "bin/bundler-audit check --update" if success?
end
