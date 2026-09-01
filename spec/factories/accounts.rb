FactoryBot.define do
  factory :account do
    sequence(:schwab_hash) { |n| Digest::SHA256.hexdigest("account-#{n}").upcase }
    account_type { "taxable" }
    trading_enabled { true }
    nickname { "Taxable" }
  end
end
