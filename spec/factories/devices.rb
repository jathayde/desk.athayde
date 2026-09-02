FactoryBot.define do
  factory :device do
    user
    platform { "ios" }
    sequence(:token) { |n| "apns-#{n}" }
    last_seen_at { Time.current }
  end
end
