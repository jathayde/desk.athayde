require "rails_helper"

RSpec.describe AlertMailer do
  include ActiveJob::TestHelper

  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let!(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:deliveries) { ActionMailer::Base.deliveries }

  before { ready_desk(account, settled: 6000) }

  it "mails an agent proposal once with its warnings, and not a human one" do
    perform_enqueued_jobs do
      Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "base breakout", origin: :agent)
    end
    expect(deliveries.map(&:subject)).to eq([ "Athayde Desk: BUY 33 XYZ waiting for you" ])
    expect(deliveries.last.text_part.body.to_s).to include("base breakout", "To acknowledge: earnings blackout and max sector exposure.", "/proposals/")
    OrderProposal.last.reject!(user: john, reason: "no")
    perform_enqueued_jobs do
      Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, origin: :human, user: john)
    end
    expect(deliveries.size).to eq(1)
    OrderProposal.last.reject!(user: john, reason: "no")
    RiskRule.active_for("notional_cap").supersede!(params: { "per_order" => "100", "per_day" => "100" }, user: john)
    perform_enqueued_jobs do
      Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, origin: :agent)
    end
    expect(deliveries.last.subject).to eq("Athayde Desk: BUY 33 XYZ rejected by rules")
  end

  it "mails a fill and a cancel as the sync records them, and a tripped rule halt, only once the state is committed" do
    proposal = create(:order_proposal, account: account, instrument: xyz, status: "submitted", broker_order_id: "o-1")
    perform_enqueued_jobs { proposal.record_broker_outcome!(:filled) }
    expect(deliveries.last.subject).to eq("Athayde Desk: BUY 10 XYZ filled")
    expect(deliveries.last.text_part.body.to_s).to include("order o-1", "The bracket's stop should now be working")
    cancelled = create(:order_proposal, account: account, instrument: create(:instrument, symbol: "DEF"), status: "submitted", kind: "exit", side: "sell", stop_price: nil)
    perform_enqueued_jobs { cancelled.record_broker_outcome!(:cancelled) }
    expect(deliveries.last.subject).to eq("Athayde Desk: SELL 10 DEF cancelled")
    expect(deliveries.last.text_part.body.to_s).not_to include("bracket")
    expect {
      OrderProposal.transaction { SystemSettings.instance.trip_rule_halt!(rule: "daily_loss_halt", reason: "down 3.2%", resets_at: nil); raise ActiveRecord::Rollback }
    }.not_to have_enqueued_mail(AlertMailer, :halt_tripped)
    perform_enqueued_jobs { SystemSettings.instance.trip_rule_halt!(rule: "daily_loss_halt", reason: "down 3.2%", resets_at: nil) }
    expect(deliveries.last.subject).to eq("Athayde Desk: entries halted by daily loss halt")
    expect(deliveries.last.text_part.body.to_s).to include("down 3.2%", "Exits and tighten-only stop changes stay available", "when you clear it on the System page")
  end

  it "refuses a new proposal while a submission on the instrument is unresolved, so nothing is mailed about it" do
    create(:order_proposal, account: account, instrument: xyz, status: "submission_unknown")
    expect {
      Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, origin: :agent)
    }.to raise_error(Proposals::Create::Refused, /pending reconciliation/)
    expect(OrderProposal.count).to eq(1)
    expect(enqueued_jobs).to be_empty
  end
end
