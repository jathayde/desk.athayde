require "rails_helper"

RSpec.describe "Watchlist" do
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }

  it "adds, lists, links to a proposal, and drops, auditing each change, for the approver only" do
    sign_in john
    post watchlist_items_path, params: { symbol: "abc", trigger: "close above 20", thesis: "base" }
    item = WatchlistItem.last
    expect(item).to have_attributes(symbol: "ABC", origin: "human", user: john)
    get watchlist_items_path
    expect(response.body).to include("ABC", "close above 20", "Propose", "Drop", "/proposals/new?symbol=ABC&amp;thesis=base")
    post watchlist_items_path, params: { symbol: "abc", trigger: "again" }
    expect(flash[:alert]).to include("already watched")
    post watchlist_item_drop_path(item)
    expect(item.reload).to be_dropped
    expect(AuditEvent.where(kind: "watchlist_changed").pluck(:reason)).to eq(%w[ added dropped ])
    post watchlist_items_path, params: { symbol: "", trigger: "" }
    expect(flash[:alert]).to include("can't be blank")

    delete session_path
    sign_in whitney
    get watchlist_items_path
    expect(response.body).not_to include("Watch a symbol")
    post watchlist_items_path, params: { symbol: "DEF", trigger: "x" }
    expect(response).to redirect_to(root_path) # the second user reads
  end
end
