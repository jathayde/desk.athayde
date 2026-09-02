require "rails_helper"

RSpec.describe Orders::ProposalLink do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  before { ready_desk(account, settled: 6000) }

  def shadow_approved
    Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :human, user: john).tap do |p|
      p.approve_and_submit!(user: john, acknowledged: %w[ max_sector_exposure earnings_blackout ])
    end
  end

  it "matches the order the operator placed by hand to a shadowed approval, once, and never when two could match" do
    proposal = shadow_approved
    bracket = create(:order, account: account, instrument: xyz, status: "WORKING", side: "BUY", order_type: "LIMIT", quantity: 33, limit_price: 50, entered_at: 10.minutes.from_now, broker_order_id: "500")
    create(:order, :working_stop, account: account, instrument: xyz, quantity: 33, remaining_quantity: 33, stop_price: 47, parent_order: bracket, broker_order_id: "500-1")
    create(:order, account: account, instrument: xyz, status: "WORKING", side: "BUY", order_type: "LIMIT", quantity: 10, limit_price: 50, entered_at: 10.minutes.from_now, broker_order_id: "501") # wrong size
    create(:order, account: account, instrument: xyz, status: "WORKING", side: "BUY", order_type: "LIMIT", quantity: 33, limit_price: 50, entered_at: 10.minutes.from_now, broker_order_id: "502") # no child stop: not a bracket
    create(:order, account: account, instrument: xyz, status: "CANCELED", side: "BUY", order_type: "LIMIT", quantity: 33, limit_price: 50, entered_at: 10.minutes.from_now, broker_order_id: "503") # dead
    described_class.call(account)
    expect(proposal.reload.broker_order_id).to eq("500")
    expect(Order.find_by(broker_order_id: "500")).to have_attributes(order_proposal: proposal, placed_via: "schwab_direct") # the operator placed it
    expect(AuditEvent.where(subject: proposal, kind: "submission_reconciled")).to exist
    described_class.call(account)
    expect(Order.find_by(broker_order_id: "500").placed_via).to eq("schwab_direct") # and a later pass does not relabel it

    proposal.reload.record_broker_outcome!(:filled) # clear the way for a second proposal on the instrument
    second = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :human, user: john)
    second.approve_and_submit!(user: john, acknowledged: %w[ max_sector_exposure earnings_blackout ])
    2.times do |i|
      parent = create(:order, account: account, instrument: xyz, status: "WORKING", side: "BUY", order_type: "LIMIT", quantity: 33, limit_price: 50, entered_at: 20.minutes.from_now, broker_order_id: "60#{i}")
      create(:order, :working_stop, account: account, instrument: xyz, quantity: 33, remaining_quantity: 33, stop_price: 47, parent_order: parent, broker_order_id: "60#{i}-1")
    end
    described_class.call(account)
    expect(second.reload.broker_order_id).to be_nil # ambiguous stays with the operator
  end

  it "links the app's own orders by broker id and records fills and cancels from the sync, never by hand" do
    proposal = shadow_approved
    proposal.update!(broker_order_id: "700", shadow: false) # as a real submission would have left it
    order = create(:order, account: account, instrument: xyz, status: "WORKING", side: "BUY", order_type: "LIMIT", quantity: 33, limit_price: 50, broker_order_id: "700")
    described_class.call(account)
    expect(order.reload).to have_attributes(order_proposal: proposal, placed_via: "app")
    order.update!(status: "FILLED")
    described_class.call(account)
    expect(proposal.reload).to be_filled
    expect(AuditEvent.where(subject: proposal, kind: "proposal_filled")).to exist
  end
end
