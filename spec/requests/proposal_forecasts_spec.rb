require "rails_helper"

# The operator's forecast on a waiting entry, blind to the agent's (docs/phase-2.6-plan.md §0.2).
RSpec.describe "Proposal forecasts" do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:xyz) { create(:instrument, symbol: "XYZ", cusip: "037833100") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }
  let(:proposal) do
    Proposals::Create.call(account: account, kind: :entry, side: :buy, symbol: "XYZ", limit_price: 50, stop_price: 47, target_price: 56, thesis: "t", origin: :agent,
                           forecast: { probability: 0.62, horizon_days: 10 })
  end

  before { ready_desk(account) && proposal }

  it "hides the agent's forecast until the operator adds theirs, then shows both" do
    sign_in john
    get proposal_path(proposal)
    expect(response.body).to include("hidden until you add yours", "Add my forecast", "What the desk saw", "formula v1", "Close against its 200-day average", "missing: 59 final candles; 200 needed")
    expect(response.body).not_to include("62.0%")
    expect(response.body).to include("The case against", "Hidden until you add your forecast", "Show it first (recorded on yours)")
    post proposal_forecast_path(proposal), params: { probability: "0.4", horizon_days: "8", saw_agent_forecast: "1" } # the form's word is not taken
    expect(response).to redirect_to(proposal_path(proposal))
    expect(proposal.forecasts.find_by(author: "human")).to have_attributes(user: john, probability: BigDecimal("0.4"), horizon_days: 8, saw_agent_forecast: false, target_price: 56)
    get proposal_path(proposal)
    expect(response.body).to include("62.0%", "40.0%", "Pending.")
    expect(response.body).not_to include("Add my forecast")
    post proposal_forecast_path(proposal), params: { probability: "0.5", horizon_days: "8" }
    expect(flash[:alert]).to include("already forecast")
  end

  it "records that the operator looked first, refuses once the proposal is decided, and lets the reader see without adding" do
    sign_in whitney
    get proposal_path(proposal)
    expect(response.body).to include("62.0%")
    post proposal_forecast_path(proposal), params: { probability: "0.4", horizon_days: "8" }
    expect(response).to redirect_to(root_path)
    delete session_path
    sign_in john
    get proposal_path(proposal)
    expect(response.body).not_to include("62.0%")
    post proposal_forecast_reveal_path(proposal)
    expect(AuditEvent.where(kind: "agent_forecast_revealed", subject: proposal).sole.user).to eq(john)
    get proposal_path(proposal)
    expect(response.body).to include("62.0%")
    post proposal_forecast_path(proposal), params: { probability: "0.7", horizon_days: "8" }
    expect(proposal.forecasts.find_by(author: "human").saw_agent_forecast).to be(true)
    other = create(:order_proposal, account: account, instrument: create(:instrument, symbol: "ABC"), target_price: 56, reference_close: 50, reference_on: MarketDay.today - 1, status: "rejected")
    post proposal_forecast_path(other), params: { probability: "0.4", horizon_days: "8" }
    expect(flash[:alert]).to include("a forecast is added while it waits")
  end
end
