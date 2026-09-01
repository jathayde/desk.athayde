require "rails_helper"

RSpec.describe MagicLinkMailer do
  let(:user) { create(:user, email_address: "john@athayde.com", name: "John") }
  let(:mail) { described_class.sign_in(user) }

  it "addresses the user with a working link in both parts" do
    expect(mail.to).to eq([ "john@athayde.com" ])
    expect(mail.from).to eq([ "desk@athayde.com" ])
    expect(mail.text_part.body.to_s).to include("15 minutes")

    [ mail.text_part, mail.html_part ].each do |part|
      token = CGI.unescape(part.body.to_s[/magic_link\?token=([^"\s]+)/, 1])
      expect(User.find_by_token_for(:magic_link, token)).to eq(user)
    end
  end
end
