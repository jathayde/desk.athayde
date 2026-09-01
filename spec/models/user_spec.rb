require "rails_helper"

RSpec.describe User do
  subject(:user) { create(:user) }

  it "normalizes the email address" do
    expect(create(:user, email_address: " John@Athayde.com ").email_address).to eq("john@athayde.com")
  end

  describe "magic links" do
    it "consumes a fresh token and returns the user" do
      expect(User.consume_magic_link(user.magic_link_token)).to eq(user)
      expect(user.reload.last_login_at).to be_present
    end

    it "is single use" do
      token = user.magic_link_token
      User.consume_magic_link(token)
      expect(User.consume_magic_link(token)).to be_nil
    end

    it "invalidates every outstanding link once one is used, even within the same second" do
      first, second = user.magic_link_token, user.magic_link_token
      expect(User.consume_magic_link(first)).to eq(user)
      expect(User.consume_magic_link(second)).to be_nil
    end

    it "expires after the TTL" do
      token = user.magic_link_token
      travel User::MAGIC_LINK_TTL + 1.second
      expect(User.consume_magic_link(token)).to be_nil
    end

    it "rejects garbage without touching the user" do
      expect(User.consume_magic_link("nope")).to be_nil
      expect(user.reload.last_login_at).to be_nil
    end
  end

  it "sends the magic link by mail" do
    expect { user.send_magic_link }.to have_enqueued_mail(MagicLinkMailer, :sign_in).with(user)
  end
end
