require "rails_helper"

RSpec.describe "Dashboard" do
  it "requires sign-in" do
    get root_path
    expect(response).to redirect_to(new_session_path)
  end

  it "shows the pre-sync empty state" do
    sign_in create(:user)
    get root_path
    expect(response.body).to include("Nothing synced yet")
  end
end
