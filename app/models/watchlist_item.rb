class WatchlistItem < ApplicationRecord
  belongs_to :instrument, optional: true
  belongs_to :user, optional: true

  enum :origin, { agent: "agent", human: "human" }
  enum :status, { watching: "watching", triggered: "triggered", dropped: "dropped" }

  normalizes :symbol, with: ->(s) { s.strip.upcase }
  validates :symbol, presence: true
end
