require "rails_helper"

RSpec.describe "Proposals" do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }

  before { ready_desk(account, settled: 6000) }

  it "previews from the form without writing, creates on propose, and shows the queue and the detail" do
    sign_in john
    get new_proposal_path(kind: "entry", symbol: "xyz", limit_price: "50", stop_price: "47", thesis: "range break")
    expect(response.body).to include("Preview: BUY 33 XYZ", "Stop collar", "Propose")
    expect(OrderProposal.count).to eq(0)
    post proposals_path, params: { kind: "entry", symbol: "xyz", limit_price: "50", stop_price: "47", thesis: "range break" }
    proposal = OrderProposal.last
    expect(response).to redirect_to(proposal_path(proposal))
    get proposals_path
    expect(response.body).to include("BUY 33 XYZ @ $50.00", "waiting for you")
    get proposal_path(proposal)
    expect(response.body).to include("I acknowledge max sector exposure", "Type approve to confirm", "Reject with a reason")
  end

  it "approves only for the approver with the typed word and the acknowledgements, and rejects with a reason" do
    proposal = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, thesis: "t", origin: :agent)
    sign_in whitney
    post proposal_approval_path(proposal), params: { confirmation: "approve", acknowledged: %w[ max_sector_exposure earnings_blackout ] }
    expect(response).to redirect_to(root_path)
    get new_proposal_path
    expect(response).to redirect_to(root_path) # the second user reads
    expect(proposal.reload).to be_validated
    delete session_path
    sign_in john
    post proposal_approval_path(proposal), params: { confirmation: "nope", acknowledged: %w[ max_sector_exposure earnings_blackout ] }
    expect(flash[:alert]).to include("Type approve")
    post proposal_approval_path(proposal), params: { confirmation: "approve", acknowledged: %w[ max_sector_exposure ] }
    expect(flash[:alert]).to include("acknowledge earnings blackout")
    post proposal_approval_path(proposal), params: { confirmation: "approve", acknowledged: %w[ max_sector_exposure earnings_blackout ] }
    expect(flash[:notice]).to include("shadow mode")
    expect(proposal.reload).to be_submitted
    get proposals_path
    expect(response.body).to include("Place by hand at Schwab", "BUY 33 XYZ @ $50.00")

    create(:instrument, symbol: "DEF", cusip: "594918104") # a second name: XYZ now carries a live entry and the exposure cap says so
    other = Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "DEF", limit_price: 50, stop_price: 47, thesis: "t", origin: :agent)
    post proposal_rejection_path(other), params: { reason: "" }
    expect(flash[:alert]).to include("reason")
    post proposal_rejection_path(other), params: { reason: "not today" }
    expect(other.reload).to have_attributes(status: "rejected", rejection_reason: "not today")
  end
end
