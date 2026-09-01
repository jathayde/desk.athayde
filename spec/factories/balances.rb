FactoryBot.define do
  factory :balance do
    account
    as_of { Time.current }
    equity { 10_000 }
  end
end
