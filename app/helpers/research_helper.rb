module ResearchHelper
  CALIBRATION_HEADINGS = { "overall" => "Overall", "author" => "By author", "paired" => "Paired: both forecasts on the same proposal and session", "setup" => "By setup, as proposed" }.freeze
  CALIBRATION_NOTES = { "overall" => "One forecast per proposal, the agent's where both forecast it, so a proposal is never two pieces of evidence.",
                        "author" => "The operator's forecast is optional, so the two are not comparable here; the paired cut is the fair comparison.",
                        "paired" => "The same proposal and the same window, the operator's made without looking at the agent's. Still not fully independent: both read the same thesis.",
                        "setup" => "Several setups make several chances of one reading \"better\" by luck." }.freeze

  def calibration_heading(scope) = CALIBRATION_HEADINGS.fetch(scope)
  def calibration_note(scope) = CALIBRATION_NOTES[scope]

  def brier(value) = value.nil? ? "n/a" : number_with_precision(value, precision: 3)
  def signed_score(value) = "#{value.negative? ? '−' : '+'}#{number_with_precision(value.abs, precision: 3)}"
  def interval_range(interval) = interval ? "#{signed_score(interval.first)} to #{signed_score(interval.last)}" : "n/a"

  def void_summary(snapshot)
    snapshot.voids.empty? ? "none void" : snapshot.voids.map { |reason, count| "#{count} #{reason.humanize(capitalize: false)}" }.to_sentence
  end

  def coverage_summary(snapshot)
    coverage = snapshot.coverage or return nil
    "on #{coverage["forecast"]} of #{pluralize(coverage["entries"], "operator entry", plural: "operator entries")}"
  end

  def reliability_summary(snapshot)
    snapshot.reliability.map { |b| "forecast #{percent(b["mean_probability"])}, observed #{percent(b["observed"])} (#{percent(b["low"], precision: 0)}–#{percent(b["high"], precision: 0)}) of #{b["n"]}" }.join(" · ")
  end

  # The headline the Sunday email and the screen share: scored count, Brier against the baseline, the verdict.
  def calibration_headline(snapshot)
    return "#{snapshot.label}: #{snapshot.verdict}" unless snapshot.scored?
    headline = "#{snapshot.label}: Brier #{brier(snapshot.brier)} against the baseline's #{brier(snapshot.baseline_brier)} (lower is better) over #{pluralize(snapshot.n, "scored forecast")}, #{snapshot.verdict}"
    snapshot.head_to_head_verdict ? "#{headline}; head to head, #{snapshot.head_to_head_verdict}" : headline
  end

  # A frozen feature in its own format, or why it is missing.
  def feature_value(features, key)
    value = features.dig("values", key)
    return "missing: #{features.dig("missing", key) || "not recorded"}" if value.nil?
    Research::Features::FEATURES.fetch(key).last == :signed_percent ? signed_percent(value.to_d) : percent(value.to_d)
  end

  def stale_calibration_note(research) = research.current? ? nil : "These are the last figures computed; no Saturday run has written any since."
end
