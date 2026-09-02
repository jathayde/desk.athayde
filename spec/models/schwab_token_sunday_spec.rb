require "rails_helper"

RSpec.describe SchwabToken, "Sunday email" do
  it "is today's email on a Sunday morning and next week's after it" do
    travel_to Time.zone.parse("2026-09-06 09:00 EDT") { expect(SchwabToken.next_sunday_email).to eq(Time.zone.parse("2026-09-06 18:00 EDT")) }
    travel_to Time.zone.parse("2026-09-06 19:00 EDT") { expect(SchwabToken.next_sunday_email).to eq(Time.zone.parse("2026-09-13 18:00 EDT")) }
    travel_to Time.zone.parse("2026-09-09 12:00 EDT") { expect(SchwabToken.next_sunday_email).to eq(Time.zone.parse("2026-09-13 18:00 EDT")) }
  end

  it "knows whether the token is covered by that email" do
    travel_to Time.zone.parse("2026-09-06 09:00 EDT") do
      expect(create(:schwab_token, issued_at: Time.zone.parse("2026-08-30 18:30 EDT"))).to be_covered_by_sunday_email
      expect(create(:schwab_token, issued_at: Time.zone.parse("2026-08-30 17:00 EDT"))).not_to be_covered_by_sunday_email
    end
  end
end
