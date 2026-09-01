FactoryBot.define do
  factory :setup do
    sequence(:name) { |n| "setup-#{n}" }
  end
end
