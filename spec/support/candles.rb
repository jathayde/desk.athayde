# A year of plausible daily candles from the fake broker, so the collar has something to measure.
module CandleHelpers
  def script_price_history(**) = Schwab::FakeClient.instance.script_daily_history(**)
end

RSpec.configure { |c| c.include CandleHelpers }
