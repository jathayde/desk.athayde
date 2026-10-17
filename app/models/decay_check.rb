# Whether an accepted hypothesis still holds (docs/phase-2.6-plan.md §0.7): the named trades closed after its frozen
# sample, their mean R and its bootstrap interval against the mean R declared before any evidence. Written on
# Saturdays from MIN_TRADES trades on, and only when the set of trades has changed since the last row. A look whose
# interval's upper end is below the declaration is marked below; it is flagged, with a suggestion, only when the
# look before it was below too and this one adds at least NEW_FOR_A_FLAG trades, since every look re-examines a
# growing sample and a single one would cry wolf. The trades read are a prefix in proposal order, so a fast loser
# never counts ahead of a slow winner proposed before it. A flag is a prompt to look, not a test. The operator
# acts, or not, in the rule editor or on the setup page; nothing is changed by the check.
class DecayCheck < ApplicationRecord
  MIN_TRADES = 20
  NEW_FOR_A_FLAG = 5 # a second look that adds fewer is the first look counted twice

  belongs_to :hypothesis

  # A row when one is due, else nil; a rerun on the same day rewrites that day's row.
  def self.record!(hypothesis, as_of:)
    trades = hypothesis.since_sample
    return nil if trades.size < MIN_TRADES
    previous = hypothesis.decay_checks.where(as_of: ...as_of).last
    today = hypothesis.decay_checks.find_by(as_of: as_of)
    return nil if (today || previous)&.trade_ids&.sort == trades.map(&:id).sort
    r = trades.map { it.realized_r.to_f }
    low, high = Research::Stats.bootstrap_interval(r).map { it.round(4) }
    below = high < hypothesis.expected_mean_r.to_f.round(4)
    flagged = below && previous&.below == true && r.size - previous.n >= NEW_FOR_A_FLAG
    transaction do
      check = today || new(hypothesis: hypothesis, as_of: as_of)
      check.update!(n: r.size, mean_r: Research::Stats.mean(r).round(4), interval_low: low, interval_high: high, expected_mean_r: hypothesis.expected_mean_r,
                    below: below, flagged: flagged, suggestion: flagged ? suggestion(hypothesis) : nil, trade_ids: trades.map(&:id), open_count: hypothesis.open_since_sample)
      AuditEvent.log("decay_check_recorded", actor: :system, subject: check, data: { hypothesis: hypothesis.id, n: check.n, mean_r: check.mean_r.to_s, below: below, flagged: flagged })
      check
    end
  end

  def self.suggestion(hypothesis)
    target = hypothesis.setup ? "the #{hypothesis.setup.name} setup" : "this hypothesis's entries"
    "Two looks running below what was declared: consider a smaller max risk per trade for #{target}, or deactivating it."
  end
  private_class_method :suggestion
end
