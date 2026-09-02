# A symbol the desk is watching, with the trigger that would make it a trade (Flow 7). Written by the human
# or the agent's tool, read by the morning brief; one watching row per symbol (a partial unique index).
class WatchlistItem < ApplicationRecord
  belongs_to :instrument, optional: true
  belongs_to :user, optional: true

  enum :origin, { agent: "agent", human: "human" }
  enum :status, { watching: "watching", triggered: "triggered", dropped: "dropped" }

  normalizes :symbol, with: ->(s) { s.strip.upcase }
  normalizes :trigger, :thesis, with: ->(text) { text.to_s.squish.presence } # one line each: nothing forges a frame line in a text email
  validates :symbol, presence: true, format: { with: /\A[A-Z.\-]{1,10}\z/, message: "must be a ticker" }
  validates :trigger, presence: true
  validates :symbol, uniqueness: { conditions: -> { watching }, message: "is already watched" }, if: :watching?

  before_validation { self.instrument ||= Instrument.find_by(symbol: symbol) }

  scope :current, -> { watching.order(:symbol) }

  def drop! = update!(status: :dropped)
end
