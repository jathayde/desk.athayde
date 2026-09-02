require "rails_helper"

RSpec.describe "System page" do
  let(:user) { create(:user, name: "John") }
  before { sign_in user }

  it "shows token status, feeds with last success, failures, honest not-yet rows, and accounts needing setup" do
    create(:schwab_token)
    account = create(:account, account_type: nil, trading_enabled: false)
    create(:sync_run, feed: "positions", account: account, status: "succeeded", started_at: 2.hours.ago, finished_at: 2.hours.ago)
    create(:sync_run, feed: "positions", account: account, status: "failed", error: "boom", started_at: 1.minute.ago)
    get system_path
    expect(response.body).to include("Healthy").and include("of 7 days").and include("no runs yet").and include("Needs setup").and include("boom").and include("last success")
  end

  it "halts with a reason and resumes with a typed confirmation, auditing both, and refuses to resume when not halted" do
    post resume_system_path, params: { confirmation: "resume" }
    expect(AuditEvent.where(kind: "manual_halt_cleared")).not_to exist
    post halt_system_path, params: { reason: "" }
    expect(SystemSettings.instance.manual_halt).to be(false)
    post halt_system_path, params: { reason: "market closed early" }
    expect(SystemSettings.instance).to have_attributes(manual_halt: true, manual_halt_reason: "market closed early")
    expect(AuditEvent.where(kind: "manual_halt_set").last.user).to eq(user)
    post resume_system_path, params: { confirmation: "nope" }
    expect(SystemSettings.instance.manual_halt).to be(true)
    post resume_system_path, params: { confirmation: "Resume" }
    expect(SystemSettings.instance.manual_halt).to be(false)
    expect(AuditEvent.where(kind: "manual_halt_cleared")).to exist
  end

  it "configures an account, audits it, and kicks off its first sync when enabled" do
    account = create(:account, account_type: nil, trading_enabled: false)
    expect {
      patch account_path(account), params: { account_type: "taxable", trading_enabled: "1", nickname: "Brokerage" }
    }.to have_enqueued_job(Sync::PositionsJob).with(account).and have_enqueued_job(Sync::OrdersJob).and have_enqueued_job(Sync::ActivitiesJob)
    expect(account.reload).to have_attributes(account_type: "taxable", trading_enabled: true, nickname: "Brokerage")
    expect(AuditEvent.where(kind: "account_configured")).to exist
  end

  it "refuses to enable trading on an IRA" do
    account = create(:account, account_type: nil, trading_enabled: false)
    patch account_path(account), params: { account_type: "ira", trading_enabled: "1" }
    expect(flash[:alert]).to include("only for the taxable account")
    expect(account.reload.trading_enabled).to be(false)
  end

  it "warns on Sunday morning only when the token dies before tonight's email" do
    travel_to Time.zone.parse("2026-09-06 09:00 EDT") do
      create(:schwab_token, issued_at: Time.zone.parse("2026-08-30 17:00 EDT"))
      get system_path
      expect(response.body).to include("dies before Sunday")
      SchwabToken.delete_all
      create(:schwab_token, issued_at: Time.zone.parse("2026-08-30 19:00 EDT"))
      get system_path
      expect(response.body).not_to include("dies before Sunday")
    end
  end
end
