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

  # The two writes the watchlist takes, each with its audit row, whoever the writer is.
  def self.watch!(symbol:, trigger:, thesis: nil, origin:, user: nil)
    transaction do
      create!(symbol: symbol, trigger: trigger, thesis: thesis, origin: origin, user: user).tap do |item|
        AuditEvent.log("watchlist_changed", actor: origin.to_sym, user: user, subject: item, reason: "added", data: { symbol: item.symbol })
      end
    end
  end

  def drop!(user: nil)
    transaction do
      update!(status: :dropped)
      AuditEvent.log("watchlist_changed", actor: user ? :human : :system, user: user, subject: self, reason: "dropped", data: { symbol: symbol })
    end
    self
  end
end
