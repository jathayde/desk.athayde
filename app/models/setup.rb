class Setup < ApplicationRecord
  has_many :trades, dependent: :restrict_with_exception
  has_many :risk_rules, dependent: :restrict_with_exception

  validates :name, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
end
