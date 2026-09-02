# The market calendar, one row per date, sourced from Schwab (which serves 7 days back to a year ahead). A fallback row (weekday 9:30 to 16:00 ET)
# drives cadence only and is re-fetched until Schwab answers.
class MarketDay < ApplicationRecord
  ZONE = "America/New_York"

  enum :source, { schwab: "schwab", fallback: "fallback" }

  validates :date, uniqueness: true

  scope :trading, -> { where(trading: true) }

  def self.today = Time.current.in_time_zone(ZONE).to_date

  def self.for(date)
    date = date.to_date
    existing = find_by(date: date)
    return existing if existing&.schwab?
    fetch(date) || existing || fallback_for(date)
  end

  def self.fetch(date)
    hours = Schwab::MarketHours.from(Schwab.client(wait: false).market_hours(date), date: date)
    row = find_or_initialize_by(date: date)
    row.update!(trading: hours.open?, session_opens_at: hours.session_opens_at, regular_opens_at: hours.regular_opens_at,
                regular_closes_at: hours.regular_closes_at, session_closes_at: hours.session_closes_at,
                raw: hours.raw, fetched_at: Time.current, source: :schwab)
    row
  rescue Schwab::Error
    nil
  end

  def self.fallback_for(date)
    zone = Time.find_zone!(ZONE)
    trading = date.on_weekday?
    create!(date: date, trading: trading, source: :fallback, fetched_at: Time.current,
            session_opens_at: trading ? zone.local(date.year, date.month, date.day, 7) : nil,
            regular_opens_at: trading ? zone.local(date.year, date.month, date.day, 9, 30) : nil,
            regular_closes_at: trading ? zone.local(date.year, date.month, date.day, 16) : nil,
            session_closes_at: trading ? zone.local(date.year, date.month, date.day, 20) : nil)
  rescue ActiveRecord::RecordNotUnique
    find_by!(date: date)
  end

  def self.session_open?(now = Time.current) = self.for(now.in_time_zone(ZONE).to_date).session_open_at?(now)

  # For requests: reads the calendar the tick maintains and never fetches. Unknown means closed.
  def self.known_session_open?(now = Time.current) = find_by(date: now.in_time_zone(ZONE).to_date)&.session_open_at?(now) || false

  def session_open_at?(now) = trading && session_opens_at <= now && now < session_closes_at
  def closed_by?(now) = trading && regular_closes_at <= now
end
