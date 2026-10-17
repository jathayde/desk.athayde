# The few statistics the research screens need, in plain Ruby with a fixed seed so every figure can be reproduced
# from the rows it was computed on (docs/phase-2.6-plan.md §0.3, §0.6).
module Research::Stats
  SEED = 2026
  DRAWS = 10_000
  Z95 = 1.959964

  module_function

  def mean(values) = values.sum(0.0) / values.size

  # The 2.5th and 97.5th percentiles of the resampled mean. With clusters (a key per value), whole clusters are
  # drawn, so values that move together, the same week's forecasts, are not counted as independent evidence.
  def bootstrap_interval(values, clusters: values.each_index.to_a, draws: DRAWS, seed: SEED)
    random = Random.new(seed)
    groups = values.zip(clusters).group_by(&:last).values.map { |rows| rows.map(&:first) }
    means = Array.new(draws) do
      drawn = Array.new(groups.size) { groups[random.rand(groups.size)] }
      drawn.sum { it.sum(0.0) } / drawn.sum(&:size)
    end.sort
    [ means[(draws * 0.025).floor], means[(draws * 0.975).ceil - 1] ]
  end

  # A one-sided test of a mean above zero by the centred bootstrap, which assumes no symmetry (R is skewed: many
  # stops near −1, a few large winners). From one set of resampled means: the p-value is the share of them, shifted
  # to a zero mean, at least as large as the observed mean (counted with the observed, so never zero); the lower
  # bound is their alpha quantile, at the same level as the bar it is judged against.
  def mean_test(values, alpha:, draws: DRAWS, seed: SEED)
    random = Random.new(seed)
    n = values.size
    observed = mean(values)
    means = Array.new(draws) { Array.new(n) { values[random.rand(n)] }.sum(0.0) / n }.sort
    p_value = (means.count { it - observed >= observed } + 1).to_f / (draws + 1)
    { p_value: p_value, lower_bound: means[(draws * alpha).floor], mean: observed }
  end

  # The Wilson score interval on k successes in n, which stays inside 0..1 at small n.
  def wilson(k, n)
    p = k.to_f / n
    centre = (p + Z95**2 / (2 * n)) / (1 + Z95**2 / n)
    half = Z95 * Math.sqrt(p * (1 - p) / n + Z95**2 / (4 * n**2)) / (1 + Z95**2 / n)
    [ centre - half, centre + half ]
  end
end
