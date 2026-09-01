class Account < ApplicationRecord
  has_many :positions, dependent: :destroy
  has_many :balances, dependent: :destroy
  has_one :current_balance, -> { order(as_of: :desc) }, class_name: "Balance"
  has_many :orders, dependent: :restrict_with_exception
  has_many :activities, dependent: :restrict_with_exception
  has_many :trades, dependent: :restrict_with_exception
  has_many :snapshots, dependent: :restrict_with_exception
  has_many :order_proposals, dependent: :restrict_with_exception

  enum :account_type, { taxable: "taxable", ira: "ira" }

  validates :schwab_hash, uniqueness: true

  scope :trading, -> { where(trading_enabled: true) }
end
