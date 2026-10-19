require "rails_helper"

RSpec.describe Agent::MorningBriefJob do
  let(:mail) { ActionMailer::Base.deliveries }
  let!(:user) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:date) { Date.new(2026, 9, 1) }

  it "records a skipped run and sends nothing on a closed day" do
    Schwab::FakeClient.instance.close_market_on(date)
    described_class.perform_now(date)
    expect(AgentRun.last).to have_attributes(kind: "morning_brief", status: "skipped", market_date: date, error: "market closed")
    expect(mail).to be_empty
  end

  it "runs once per market day, emails the brief, stamps emailed_at, and sweeps a stuck row first" do
    stuck = AgentRun.create!(kind: :eod, market_date: date - 1, status: :running, started_at: 30.minutes.ago)
    described_class.perform_now(date)
    run = AgentRun.morning_brief.last
    expect(run).to have_attributes(status: "succeeded", market_date: date)
    expect(run.emailed_at).to be_present
    expect(mail.map(&:subject)).to eq([ "DEGRADED: Athayde Desk: morning brief, Tue Sep 1" ])
    expect(stuck.reload.status).to eq("failed")

    described_class.perform_now(date)
    expect(AgentRun.morning_brief.count).to eq(1)
    expect(mail.size).to eq(1)
  end

  it "keeps the finished run when delivery fails so it can be resent without another API call" do
    allow(BriefMailer).to receive(:brief).and_raise(Net::SMTPServerBusy, "busy")
    expect { described_class.perform_now(date) }.to raise_error(Net::SMTPServerBusy)
    run = AgentRun.morning_brief.last
    expect(run).to have_attributes(status: "succeeded", emailed_at: nil)
    allow(BriefMailer).to receive(:brief).and_call_original
    run.deliver!
    expect(run.reload.emailed_at).to be_present
    expect(Agent::FakeAnthropic.instance.requests.size).to eq(1)
    expect { AgentRun.create!(kind: :eod, market_date: date, status: :skipped, started_at: Time.current).deliver! }.to raise_error(ArgumentError, /skipped/)
  end

  it "finishes the row and still emails when the run cannot even be built" do
    allow(Agent).to receive(:client).and_raise(Agent::NotConfigured, "anthropic.api_key is not in credentials")
    expect { described_class.perform_now(date) }.to raise_error(Agent::NotConfigured)
    run = AgentRun.morning_brief.last
    expect(run).to have_attributes(status: "failed", error: "Agent::NotConfigured: anthropic.api_key is not in credentials")
    expect(run.emailed_at).to be_present
    expect(mail.last.subject).to start_with("FAILED:")
  end

  it "emails a failed run as unavailable rather than staying silent" do
    Agent::FakeAnthropic.instance.enqueue { raise Anthropic::Errors::InternalServerError.new(url: URI("https://api.anthropic.com/v1/messages"), status: 500, headers: {}, body: nil, request: nil, response: nil, message: "boom") }
    described_class.perform_now(date)
    expect(AgentRun.last.status).to eq("failed")
    expect(mail.last.subject).to start_with("FAILED:")
    expect(mail.last.text_part.body.to_s).to include("The brief is unavailable: Anthropic InternalServerError")
  end

  it "waits for live feed and memory runs before reading, then proceeds at the limit even if they never finish" do
    SyncRun.create!(feed: :memory_repo, status: :running, started_at: 1.minute.ago)
    calls = 0
    allow_any_instance_of(described_class).to receive(:sleep) { calls += 1; SyncRun.running.update_all(status: "succeeded") if calls == 2 }
    described_class.perform_now(date)
    expect(calls).to eq(2)

    SyncRun.create!(feed: :positions, status: :running, started_at: 1.minute.ago)
    calls = 0
    allow_any_instance_of(described_class).to receive(:sleep) { |_, seconds| calls += 1; travel(seconds) }
    described_class.perform_now(date - 1)
    expect(calls).to be_within(1).of(Agent::BriefJob::WAIT_FOR_SYNC / Agent::BriefJob::POLL) # travel truncates to the second
    expect(AgentRun.where(market_date: date - 1).last.status).to eq("succeeded")
  end
end

RSpec.describe Agent::EndOfDayJob do
  it "is the same job for the eod kind" do
    create(:user, email_address: "john@athayde.com", approver: true)
    described_class.perform_now(Date.new(2026, 9, 1))
    expect(AgentRun.last).to have_attributes(kind: "eod", status: "succeeded")
  end
end

RSpec.describe Agent::SundayReviewJob do
  it "records a run without tokens and sends the Sunday email once" do
    create(:user, email_address: "john@athayde.com", approver: true)
    described_class.perform_now(Date.new(2026, 9, 6))
    described_class.perform_now(Date.new(2026, 9, 6))
    expect(AgentRun.sunday_review.count).to eq(1)
    expect(AgentRun.last).to have_attributes(status: "succeeded", input_tokens: nil, estimated_cost: nil, title: "Sunday review, Sun Sep 6")
    expect(AgentRun.last.emailed_at).to be_present
    expect(ActionMailer::Base.deliveries.map(&:subject)).to eq([ "Athayde Desk: Sunday review, re-authenticate Schwab" ])
  end
end
