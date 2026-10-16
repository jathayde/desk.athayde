require "rails_helper"

RSpec.describe "db/seeds.rb" do
  it "loads idempotently and creates exactly the allowlisted users outside development" do
    2.times { Rails.application.load_seed }
    expect(User.pluck(:email_address)).to contain_exactly("john@athayde.com", "whitney@athayde.com")
    expect(Account.count + SchwabToken.count + AgentRun.count).to eq(0)
    expect(RiskRule.active.scope_book.pluck(:rule_type)).to contain_exactly(*RiskRule::BOOK_TYPES)
    expect(DeploymentPolicy.sole).to have_attributes(mode: "ask", active: true, version: 1)
  end

  it "seeds a whole desk through the fake broker and fake model in development, once" do
    allow(Rails.env).to receive(:development?).and_return(true)
    adapter = ActiveJob::Base.queue_adapter
    begin
      2.times { Rails.application.load_seed } # the seed switches the process to the inline adapter
    ensure
      ActiveJob::Base.queue_adapter = adapter
    end
    expect(Account.count).to eq(1)
    expect(Desk.new.state).to eq(:ready)
    expect(Trade.journaled.closed.count).to be >= 1
    expect(Setup.find_by!(name: "Breakout").sample_size).to eq(1)
    expect(AgentRun.morning_brief.count).to eq(1)
    expect(AgentRun.last.emailed_at).to be_present
    expect(SyncRun.failed.count).to eq(1)
  end
end
