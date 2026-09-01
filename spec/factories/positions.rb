FactoryBot.define do
  factory :position do
    account
    instrument
    quantity { 40 }
    average_price { 51.18 }
    last_price { 53.00 }
    synced_at { Time.current }
  end
end
