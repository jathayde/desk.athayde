require "rails_helper"

RSpec.describe Alert do
  include ActiveJob::TestHelper

  let(:apns) { Push::FakeApns.instance }
  let!(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:proposal) { create(:order_proposal, account: account, instrument: xyz, status: "submitted", broker_order_id: "secret-order-9", thesis: "base " * 60) }

  before { create(:device, user: john, token: "john-1") }

  def last_pair
    mail = ActionMailer::Base.deliveries.last
    push = apns.pushed.last
    expect(push.alert[:title]).to eq(mail.subject.delete_prefix("Athayde Desk: ").upcase_first) # the same sentence, once as a subject and once as a title
    [ mail, push ]
  end

  it "new_proposal: the status as the sentence, the thesis capped as the body, the proposal as the path" do
    proposal.update!(status: "validated")
    perform_enqueued_jobs { described_class.new_proposal(proposal) }
    mail, push = last_pair
    expect(push.alert).to include(title: "BUY 10 XYZ waiting for you")
    expect(push.alert[:body].length).to be <= Alert::BODY_LIMIT
    expect(push.custom_payload).to eq(path: "/proposals/#{proposal.id}")
    expect(mail.text_part.body.to_s).to include("base base")
  end

  it "fill_or_cancel: the broker's outcome, and never the order id" do
    perform_enqueued_jobs { described_class.fill_or_cancel(proposal) }
    _, push = last_pair
    expect(push.alert).to eq(title: "BUY 10 XYZ submitted", body: "At Schwab. Open the proposal for the order.")
    expect(push.body).not_to include("secret-order-9")
  end

  it "submission_unknown and late_submission point at the proposal" do
    perform_enqueued_jobs { described_class.submission_unknown(proposal) }
    _, push = last_pair
    expect(push.alert[:title]).to eq("A submission on XYZ is unresolved")
    perform_enqueued_jobs { described_class.late_submission(proposal) }
    _, push = last_pair
    expect(push.alert[:title]).to eq("BUY 10 XYZ is working at Schwab after all")
    expect(push.custom_payload).to eq(path: "/proposals/#{proposal.id}")
  end

  it "halt_tripped points at the system page; unprotected_position at the dashboard" do
    perform_enqueued_jobs { described_class.halt_tripped(rule: "daily_loss_halt", reason: "down 3.2%", resets_at: nil) }
    _, push = last_pair
    expect(push.alert).to eq(title: "Entries halted by daily loss halt", body: "down 3.2%. Exits stay available.")
    expect(push.custom_payload).to eq(path: "/system")
    position = create(:position, account: account, instrument: xyz, working_stop_order: nil)
    perform_enqueued_jobs { described_class.unprotected_position(position) }
    _, push = last_pair
    expect(push.alert[:title]).to eq("XYZ is unprotected")
    expect(push.custom_payload).to eq(path: "/")
  end
end
