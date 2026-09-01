FactoryBot.define do
  factory :instrument do
    sequence(:cusip) { |n| format("%09d", n) }
    sequence(:symbol) { |n| "SYM#{n}" }
    asset_type { "EQUITY" }
  end
end
