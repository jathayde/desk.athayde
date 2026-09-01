module Schwab
  # JSON floats through Float drift; every money and quantity value goes through here.
  module Decimal
    ZERO = BigDecimal("0")

    def self.parse(value)
      return nil if value.nil? || value == ""
      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def self.parse_or_zero(value) = parse(value) || ZERO
  end
end
