FactoryBot.define do
  factory :snapshot do
    account
    as_of { Date.current }
    equity { 10_000 }
    index_value { 1 }
    high_water_index { 1 }
  end
end
