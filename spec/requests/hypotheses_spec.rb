require "rails_helper"

RSpec.describe "Hypotheses" do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }
  let!(:breakout) { create(:setup, name: "Breakout") }

  before { ready_desk(account) }

  it "is written on the research screen, tested, named on an entry from the form, and shown with its progress" do
    sign_in john
    post hypotheses_path, params: { hypothesis: { statement: "Breakouts pay", rules: "close above the 20-day high", setup_id: breakout.id, min_sample: 10, holdout_from: MarketDay.today - 3, expected_mean_r: "0.4" } }
    expect(flash[:alert]).to include("cannot be before today")
    post hypotheses_path, params: { hypothesis: { statement: "Breakouts pay", rules: "close above the 20-day high", setup_id: breakout.id, min_sample: 10, holdout_from: MarketDay.today, expected_mean_r: "0.4" } }
    hypothesis = Hypothesis.sole
    post hypothesis_testing_path(hypothesis), params: { reason: "" }
    expect(flash[:alert]).to include("reason is required")
    post hypothesis_testing_path(hypothesis), params: { reason: "a quiet tape for breakouts" }
    expect(hypothesis.reload).to be_status_testing
    get new_proposal_path
    expect(response.body).to include("Evidence for a hypothesis under test", "##{hypothesis.id} Breakouts pay (Breakout)")
    post proposals_path, params: { kind: "entry", symbol: "XYZ", limit_price: "50", stop_price: "47", thesis: "t", hypothesis_id: hypothesis.id }
    unnamed = OrderProposal.last
    expect(unnamed).to have_attributes(hypothesis: nil, setup: nil) # the hypothesis never supplies a setup, which sizing reads
    expect(AuditEvent.where(kind: "hypothesis_not_named", subject: unnamed).sole.reason).to include("name that setup")
    unnamed.reject!(user: john, reason: "again, with the setup")
    post proposals_path, params: { kind: "entry", symbol: "XYZ", limit_price: "50", stop_price: "47", thesis: "t", hypothesis_id: hypothesis.id, setup_id: breakout.id }
    proposal = OrderProposal.last
    expect(proposal).to have_attributes(hypothesis: hypothesis, setup: breakout)
    get proposal_path(proposal)
    expect(response.body).to include("evidence for", "hypothesis ##{hypothesis.id}")
    get research_path
    expect(response.body).to include("1 hypothesis tested so far", "Breakouts pay", "0 of 10 trades closed")
    expect(response.body).not_to include("Verdict")
  end

  it "is the approver's to write and decide; the reader sees it" do
    hypothesis = Hypothesis.write!({ statement: "Pullbacks pay", rules: "r", min_sample: 10, holdout_from: MarketDay.today, expected_mean_r: 0.3 }, user: john)
    sign_in whitney
    post hypothesis_testing_path(hypothesis), params: { reason: "x" }
    expect(response).to redirect_to(root_path)
    get research_path
    expect(response.body).to include("Pullbacks pay")
    expect(response.body).not_to include("Write a hypothesis")
  end
end
