require "rails_helper"

RSpec.describe "db/seeds.rb" do
  it "loads idempotently and creates exactly the allowlisted users" do
    2.times { Rails.application.load_seed }
    expect(User.pluck(:email_address)).to contain_exactly("john@athayde.com", "whitney@athayde.com")
  end
end
