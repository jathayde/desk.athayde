FactoryBot.define do
  factory :user do
    sequence(:email_address) { |n| "person#{n}@athayde.com" }
    name { "Person" }
  end
end
