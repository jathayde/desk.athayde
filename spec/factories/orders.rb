FactoryBot.define do
  factory :order do
    account
    instrument
    sequence(:broker_order_id) { |n| (1_000_000 + n).to_s }
    status { "FILLED" }
    side { "BUY" }
    quantity { 10 }
    order_type { "LIMIT" }
    entered_at { Time.current }

    trait :working_stop do
      status { "WORKING" }
      side { "SELL" }
      order_type { "STOP" }
      stop_price { 48.90 }
    end

    trait :trailing_stop do
      status { "WORKING" }
      side { "SELL" }
      order_type { "TRAILING_STOP" }
      stop_price { nil }
    end
  end
end
