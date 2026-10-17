# What the levels, the horizon, and the volatility alone imply (docs/phase-2.6-plan.md §0.3): the chance that a
# price with no expected drift, moving at the forecast's reference volatility, meets the claim under the resolver's
# own rules (Forecast::Resolution): from the entry, the rest of the entry day tests only the stop; then horizon_days
# sessions, a day reaching both levels counted as the stop, and a horizon that runs out a miss. Simulated, each
# day's high and low drawn from the Brownian bridge between its open and close, with a seed fixed per forecast so
# the number is reproducible. A forecaster who cannot beat this has said nothing the levels and the tape did not.
module Research::Baseline
  VERSION = 1
  PATHS = 2_000
  ENTRY_DAY_LEFT = 0.5 # the share of the entry session after the limit is touched, on average

  module_function

  def probability(entry:, stop:, target:, volatility:, horizon_days:, seed:)
    random = Random.new(seed)
    sigma = volatility.to_f
    up, down = Math.log(target.to_f / entry.to_f), Math.log(stop.to_f / entry.to_f)
    hits = PATHS.times.count do
      x = 0.0
      x, _, low = session(x, sigma * Math.sqrt(ENTRY_DAY_LEFT), random)
      next false if low <= down
      horizon_days.times.any? do
        x, high, low = session(x, sigma, random)
        break false if low <= down
        high >= up
      end
    end
    (hits.to_f / PATHS).round(4)
  end

  # One session's close, high, and low in log price from its open, with no drift in price (−σ²/2 in log).
  def session(open, sigma, random)
    close = open - sigma**2 / 2 + sigma * gaussian(random)
    spread = (close - open)**2
    high = (open + close + Math.sqrt(spread - 2 * sigma**2 * Math.log(1 - random.rand))) / 2
    low = (open + close - Math.sqrt(spread - 2 * sigma**2 * Math.log(1 - random.rand))) / 2
    [ close, high, low ]
  end

  def gaussian(random) = Math.sqrt(-2 * Math.log(1 - random.rand)) * Math.cos(2 * Math::PI * random.rand)
end
