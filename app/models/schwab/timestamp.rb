module Schwab
  # Schwab uses three timestamp formats in and three out. Nothing else in the app formats a Schwab time.
  module Timestamp
    OFFSET_WITHOUT_COLON = /([+-]\d{2})(\d{2})\z/

    # "+0000", "Z", "-04:00", or epoch milliseconds (integer or numeric string).
    def self.parse(value)
      return nil if value.blank?
      return ::Time.zone.at(Rational(value.to_i, 1000)) if value.is_a?(Integer) || value.to_s.match?(/\A\d{12,}\z/)
      ::Time.zone.iso8601(value.to_s.sub(OFFSET_WITHOUT_COLON, '\1:\2'))
    rescue ArgumentError
      raise MappingError, "unparseable timestamp #{value.inspect}"
    end

    # tradeDate and settlementDate arrive as UTC midnights; read them as UTC or the date slips a day in New York.
    def self.parse_date(value) = parse(value)&.utc&.to_date

    # Orders and transactions: yyyy-MM-dd'T'HH:mm:ss.SSSZ in UTC.
    def self.iso_ms(time) = time.getutc.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    # Market hours: YYYY-MM-DD.
    def self.date(date) = date.to_date.iso8601

    # Price history: epoch milliseconds.
    def self.epoch_ms(time) = (time.to_r * 1000).to_i

    # Daily candles stamp midnight Eastern expressed in UTC; read them in New York.
    def self.candle_date(epoch_ms)
      raise MappingError, "candle without datetime" if epoch_ms.blank?
      ::Time.at(Rational(epoch_ms, 1000)).in_time_zone("America/New_York").to_date
    end
  end
end
