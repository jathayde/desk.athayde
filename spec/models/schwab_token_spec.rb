require "rails_helper"

RSpec.describe SchwabToken do
  it "encrypts tokens at rest" do
    token = SchwabToken.create!(access_token: "access-abc", refresh_token: "refresh-xyz", access_expires_at: 30.minutes.from_now,
                                refresh_expires_at: 7.days.from_now, issued_at: Time.current)
    stored = SchwabToken.lease_connection.select_one(SchwabToken.sanitize_sql([ "SELECT access_token, refresh_token FROM schwab_tokens WHERE id = ?", token.id ]))
    expect(stored["access_token"]).not_to eq("access-abc")
    expect(stored["refresh_token"]).not_to eq("refresh-xyz")
    expect(token.reload).to have_attributes(access_token: "access-abc", refresh_token: "refresh-xyz")
  end
end
