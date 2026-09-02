require "rails_helper"

RSpec.describe Jobs::FailureDigestJob do
  let!(:user) { create(:user, email_address: "john@athayde.com") }

  it "sends nothing when the last 24 hours were clean, ignoring token-skipped runs, a closed-day skip, and older failures" do
    SyncRun.create!(feed: :positions, status: :skipped_token, started_at: 1.hour.ago, finished_at: 1.hour.ago)
    SyncRun.create!(feed: :orders, status: :failed, started_at: 30.hours.ago, finished_at: 30.hours.ago, error: "old")
    AgentRun.create!(kind: :morning_brief, market_date: Date.yesterday, status: :skipped, started_at: 2.hours.ago, finished_at: 2.hours.ago, error: "market closed")
    described_class.perform_now
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "sweeps stuck runs and reports them as failed, with undelivered briefs and failed jobs by class" do
    AgentRun.create!(kind: :eod, market_date: Date.yesterday, status: :running, started_at: 40.minutes.ago)
    unsent = AgentRun.create!(kind: :morning_brief, market_date: Date.yesterday, status: :succeeded, started_at: 3.hours.ago, finished_at: 3.hours.ago)
    job = SolidQueue::Job.create!(class_name: "Sync::PositionsJob", queue_name: "default", active_job_id: SecureRandom.uuid)
    SolidQueue::FailedExecution.create!(job: job, error: { "exception_class" => "Schwab::ServerError", "message" => "503 from Schwab", "backtrace" => [] })
    described_class.perform_now
    expect(AgentRun.eod.last.status).to eq("failed")
    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq("Athayde Desk: failures in the last 24 hours")
    expect(mail.text_part.body.to_s).to include("end of day, #{Date.yesterday.strftime('%a %b %-d')}: failed: left running",
                                                "morning brief, #{Date.yesterday.strftime('%a %b %-d')}: succeeded but never emailed (bin/rails agent:resend[#{unsent.id}])",
                                                "Sync::PositionsJob: 1 failed job", "Schwab::ServerError: 503 from Schwab")
  end
end
