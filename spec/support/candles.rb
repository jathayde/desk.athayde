# A year of plausible daily candles for the fake broker, so the collar has something to measure.
module CandleHelpers
  def script_price_history(symbol: "XYZ", days: 60, close: 50, range: 1, ending: MarketDay.today)
    candles = (1..days).map do |i|
      date = ending - (days - i)
      zone = Time.find_zone!(MarketDay::ZONE)
      c = close + Math.sin(i / 3.0) # a gentle wave, never flat
      { "datetime" => zone.local(date.year, date.month, date.day, 6).to_i * 1000, "open" => c - 0.2, "high" => c + range, "low" => c - range, "close" => c, "volume" => 1_000_000 }
    end
    Schwab::FakeClient.instance.enqueue(:price_history, sticky: true) { { "candles" => candles, "symbol" => symbol, "empty" => false, "previousClose" => close } }
  end
end

RSpec.configure { |c| c.include CandleHelpers }
