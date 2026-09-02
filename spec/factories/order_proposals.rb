FactoryBot.define do
  factory :order_proposal do
    account
    instrument
    kind { "entry" }
    origin { "human" }
    side { "buy" }
    status { "validated" }
    quantity { 10 }
    limit_price { 50 }
    stop_price { 47 }
  end
end
