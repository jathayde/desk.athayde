FactoryBot.define do
  factory :activity do
    account
    instrument
    sequence(:broker_activity_id) { |n| (90_000_000 + n).to_s }
    kind { "fill" }
    side { "BUY" }
    quantity { 40 }
    price { 51.18 }
    executed_at { Time.current }
  end
end
