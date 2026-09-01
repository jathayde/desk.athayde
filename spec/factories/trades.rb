FactoryBot.define do
  factory :trade do
    account
    instrument
    status { "open" }
  end
end
