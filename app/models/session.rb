class Session < ApplicationRecord
  LIFETIME = 30.days

  belongs_to :user

  scope :current, -> { where(created_at: LIFETIME.ago..) }
end
