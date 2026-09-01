FactoryBot.define do
  factory :sync_run do
    feed { "orders" }
    status { "succeeded" }
    started_at { Time.current }
    finished_at { Time.current }
  end
end
