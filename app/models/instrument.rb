class Instrument < ApplicationRecord
  belongs_to :predecessor_instrument, class_name: "Instrument", optional: true
  has_many :positions, dependent: :restrict_with_exception
  has_many :orders, dependent: :restrict_with_exception
  has_many :activities, dependent: :restrict_with_exception
  has_many :trades, dependent: :restrict_with_exception

  normalizes :cusip, with: ->(c) { c.strip.upcase.presence }
  normalizes :symbol, with: ->(s) { s.strip.upcase }

  validates :symbol, presence: true
  validate :predecessor_is_another_instrument

  def rename!(new_symbol, at: Time.current)
    return if new_symbol == symbol
    update!(symbol: new_symbol, symbol_history: symbol_history + [ { "symbol" => symbol, "until" => at.utc.iso8601 } ])
  end

  private
    def predecessor_is_another_instrument
      errors.add(:predecessor_instrument, "cannot be itself") if persisted? && predecessor_instrument_id == id
    end
end
