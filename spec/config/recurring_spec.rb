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

  it "briefs at 07:03 and 16:30 on weekdays after the 07:00 tick, reviews Sunday at 18:00, and digests at 17:15" do
    morning = Fugit::Cron.parse(tasks.dig("agent_morning_brief", "schedule"))
    expect([ morning.hours, morning.minutes, morning.weekdays.flatten ]).to eq([ [ 7 ], [ 3 ], [ 1, 2, 3, 4, 5 ] ])
    expect(Fugit::Cron.parse(tasks.dig("sync_tick", "schedule")).minutes).to include(0)
    expect(Fugit::Cron.parse(tasks.dig("agent_end_of_day", "schedule")).hours).to eq([ 16 ])
    expect(Fugit::Cron.parse(tasks.dig("agent_sunday_review", "schedule")).weekdays.flatten).to eq([ 0 ])
    expect(Fugit::Cron.parse(tasks.dig("failure_digest", "schedule")).hours).to eq([ 17 ])
    expect(Fugit::Cron.parse(tasks.dig("stop_collar_trails", "schedule"))).to have_attributes(hours: [ 16 ], minutes: [ 10 ]) # before the 16:30 end-of-day
  end

  it "refreshes the token every 25 minutes and checks health at 08:00 and 20:00" do
    expect(Fugit::Cron.parse(tasks.dig("schwab_refresh_access_token", "schedule")).minutes).to eq([ 0, 25, 50 ])
    expect(Fugit::Cron.parse(tasks.dig("schwab_token_health", "schedule")).hours).to eq([ 8, 20 ])
  end
end
