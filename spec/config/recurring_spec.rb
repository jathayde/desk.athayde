require "rails_helper"
require "fugit"

# Solid Queue skips a recurring task it cannot parse without failing boot, so the schedules are asserted here.
RSpec.describe "config/recurring.yml" do
  let(:tasks) { YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production") }

  it "parses every schedule as cron in New York time" do
    tasks.each_value do |task|
      cron = Fugit::Cron.parse(task.fetch("schedule"))
      expect(cron).to be_a(Fugit::Cron), "#{task["class"]} schedule did not parse"
      expect(cron.timezone.name).to eq("America/New_York")
      expect(task.fetch("class").constantize).to be < ApplicationJob
    end
  end

  it "refreshes the token every 25 minutes and checks health at 08:00 and 20:00" do
    expect(Fugit::Cron.parse(tasks.dig("schwab_refresh_access_token", "schedule")).minutes).to eq([ 0, 25, 50 ])
    expect(Fugit::Cron.parse(tasks.dig("schwab_token_health", "schedule")).hours).to eq([ 8, 20 ])
  end
end
