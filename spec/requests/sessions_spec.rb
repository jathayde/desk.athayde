require "rails_helper"

RSpec.describe "Sessions" do
  let!(:user) { create(:user, email_address: "john@athayde.com") }

  before { Rails.cache.clear }

  describe "POST /session" do
    it "emails a link to a known address, however it was typed" do
      expect {
        post session_path, params: { email_address: " John@Athayde.com " }
      }.to have_enqueued_mail(MagicLinkMailer, :sign_in).with(user)
      expect(response).to redirect_to(new_session_path)
      follow_redirect!
      expect(response.body).to include("a sign-in link is on its way")
    end

    it "gives an unknown address the identical response and no email" do
      expect {
        post session_path, params: { email_address: "stranger@example.com" }
      }.not_to have_enqueued_mail
      expect(response).to redirect_to(new_session_path)
      follow_redirect!
      expect(response.body).to include("a sign-in link is on its way")
    end

    it "rate limits link requests" do
      10.times { post session_path, params: { email_address: "stranger@example.com" } }
      post session_path, params: { email_address: "stranger@example.com" }
      expect(flash[:alert]).to eq("Try again later.")
    end
  end

  describe "DELETE /session" do
    it "signs out" do
      sign_in user
      delete session_path
      expect(response).to redirect_to(new_session_path)
      get root_path
      expect(response).to redirect_to(new_session_path)
    end
  end

  describe "session lifetime" do
    it "expires server-side after 30 days" do
      sign_in user
      get root_path
      expect(response).to have_http_status(:ok)
      travel Session::LIFETIME + 1.day
      get root_path
      expect(response).to redirect_to(new_session_path)
    end
  end
end
