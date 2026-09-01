FactoryBot.define do
  factory :schwab_token do
    access_token { "access-#{SecureRandom.hex(4)}" }
    refresh_token { "refresh-#{SecureRandom.hex(4)}" }
    issued_at { Time.current }
    access_expires_at { issued_at + 29.minutes }
    refresh_expires_at { issued_at + SchwabToken::REFRESH_LIFETIME }
    scope { "api" }

    trait :revoked do
      revoked_at { Time.current }
    end
  end
end
