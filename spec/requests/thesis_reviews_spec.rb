require "rails_helper"

RSpec.describe "Thesis reviews" do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let!(:tqqq) { create(:instrument, symbol: "TQQQ") }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }
  let(:context) { { "as_of" => "2026-10-14", "weight" => "0.212", "target_weight" => "0.1", "drift" => "0.112", "band" => "0.05", "close" => "53", "notional" => "-1120", "quantity" => "40", "unrealized_pnl" => "520" } }

  before do
    tqqq.classify!(asset_class: nil, tags: %w[ leveraged ], user: john)
    create(:balance, account: account, equity: 10_000, as_of: Time.current)
  end

  def review = ThesisReview.create!(account: account, instrument: tqqq, reason: :drift, context: context)

  it "sits in the queue and on the dashboard, shows the thesis gap and the numbers, and deploys or exits into the prefilled form" do
    deploy = review
    sign_in john
    get proposals_path
    expect(response.body).to include("Thesis review: TQQQ", "deploy, hold, or exit")
    get root_path
    expect(response.body).to include("1 thesis review")
    get thesis_review_path(deploy)
    expect(response.body).to include("tagged leveraged", "No thesis on file", "21.2% against a 10.0% target", "sell $1,120.00", "+$520.00 unrealized")
    post thesis_review_decision_path(deploy), params: { decision: "deploy" }
    expect(response).to redirect_to(new_proposal_path(kind: "entry", symbol: "TQQQ", limit_price: "53.0", thesis: nil))
    expect(deploy.reload.decision).to eq("deploy")

    exiting = review
    post thesis_review_decision_path(exiting), params: { decision: "exit" }
    expect(response).to redirect_to(new_proposal_path(kind: "exit", symbol: "TQQQ", limit_price: "53.0", thesis: nil))
  end

  it "holds only with a reason, refuses a second decision, and keeps the second user to reading" do
    held = review
    sign_in john
    post thesis_review_decision_path(held), params: { decision: "vibes" }
    expect(flash[:alert]).to eq("choose deploy, hold, or exit")
    post thesis_review_decision_path(held), params: { decision: "hold" }
    expect(flash[:alert]).to eq("a hold needs a reason")
    expect(held.reload).to have_attributes(decision: nil, decided_at: nil)
    post thesis_review_decision_path(held), params: { decision: "hold", reason: "riding it" }
    expect(response).to redirect_to(proposals_path)
    post thesis_review_decision_path(held), params: { decision: "exit" }
    expect(flash[:alert]).to eq("That review was decided or refreshed since you opened it; look again.")

    delete session_path
    sign_in whitney
    other = review
    get thesis_review_path(other)
    expect(response.body).not_to include("Hold, because")
    post thesis_review_decision_path(other), params: { decision: "exit" }
    expect(flash[:alert]).to eq("Only the approver can do that.")
    expect(other.reload).to be_open
  end

  it "renders the page and the mail for a review with no numbers, and says when the tag is gone" do
    tqqq.classify!(asset_class: nil, tags: [], user: john)
    sparse = ThesisReview.create!(account: account, instrument: tqqq, reason: :drift, context: {})
    sign_in john
    get thesis_review_path(sparse)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("no longer tagged", "no close recorded", "No active target")
    expect(response.body).not_to include("Exit (sell)") # nothing held to sell
    mail = AlertMailer.thesis_review(sparse, subject: "TQQQ drifted: thesis review")
    expect(mail.text_part.body.to_s).to include("Thesis: none on file")
  end
end

RSpec.describe "Deposit reviews and deployment proposals" do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  it "shows a deposit review with its three answers and deploys it tonight, and a deployment proposal shows its context" do
    policy = DeploymentPolicy.create!(mode: "ask")
    activity = create(:activity, account: account, instrument: nil, kind: "deposit", side: nil, quantity: nil, price: nil, net_amount: 2000, trade_date: Date.new(2026, 10, 14))
    inflow = CashInflow.create_from!(account, activity, policy)
    sign_in john
    get proposals_path
    expect(response.body).to include("Deposit: $2,000.00 deposited Oct 14", "deploy, stage, or hold")
    get thesis_review_path(inflow.thesis_review)
    expect(response.body).to include("New cash: $2,000.00 deposited Oct 14", "Deploy at the next check", "Stage over this many weeks", "Hold as cash, because")
    post thesis_review_decision_path(inflow.thesis_review), params: { decision: "deploy" }
    expect(flash[:notice]).to eq("$2,000.00 deposited Oct 14: deploying at the next check.")
    expect(inflow.reload).to be_status_pending

    proposal = create(:order_proposal, account: account, kind: "rebalance", origin: "allocation", allocation_source: inflow, stop_price: nil,
                                       context: { "source" => inflow.label, "share" => "1333.33", "notes" => nil })
    get proposal_path(proposal)
    expect(response.body).to include("Deployment context", "$1,333.33 of it to this target", "No deployment.md in the memory repo yet")
  end
end
