FactoryBot.define do
  factory :user do
    sequence(:email_address) { |n| "person#{n}@athayde.com" }
    name { "Person" }
    notify { true } # the production default is off for anyone but the approver; specs that care say so
  end
end
