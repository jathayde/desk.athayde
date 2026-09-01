require "rails_helper"

RSpec.describe "Magic links" do
  let!(:user) { create(:user, email_address: "john@athayde.com") }

  describe "GET /magic_link" do
    it "renders a confirm page with no side effects, so scanners cannot burn the link" do
      token = user.magic_link_token
      get magic_link_path(token: token)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Continue to Athayde Desk")
      expect(user.reload.last_login_at).to be_nil
      expect(Session.count).to eq(0)
      get root_path
      expect(response).to redirect_to(new_session_path)
      expect(User.consume_magic_link(token)).to eq(user)
    end
  end

  describe "POST /magic_link" do
    it "signs the user in and records the login" do
      post magic_link_path, params: { token: user.magic_link_token }
      expect(response).to redirect_to(root_url)
      expect(user.reload.last_login_at).to be_present
      get root_path
      expect(response).to have_http_status(:ok)
    end

    it "honors the return-to path captured before login" do
      get root_path(view: "risk")
      expect(response).to redirect_to(new_session_path)
      post magic_link_path, params: { token: user.magic_link_token }
      expect(response).to redirect_to(root_url(view: "risk"))
    end

    it "rejects a used link" do
      token = user.magic_link_token
      post magic_link_path, params: { token: token }
      delete session_path
      post magic_link_path, params: { token: token }
      expect(response).to redirect_to(new_session_path)
      expect(flash[:alert]).to match(/invalid or has expired/)
    end

    it "rejects an expired link" do
      token = user.magic_link_token
      travel User::MAGIC_LINK_TTL + 1.minute
      post magic_link_path, params: { token: token }
      expect(response).to redirect_to(new_session_path)
    end
  end
end
