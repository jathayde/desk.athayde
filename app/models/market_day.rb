class MarketDay < ApplicationRecord
  enum :source, { schwab: "schwab", fallback: "fallback" }

  validates :date, uniqueness: true

  scope :trading, -> { where(trading: true) }
end
