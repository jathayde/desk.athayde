# The one thing that turns drift into proposals (docs/phase-2.5-plan.md §0.6). For each line outside its band it
# decides, under the account-and-instrument lock Proposals::Create also takes, whether the desk may propose:
# never on a class (no instrument to order) or a leveraged or amplified instrument (which asks the operator in a
# thesis review instead),
# never beside a waiting or unresolved proposal on the instrument, never again while a rejection stands, never
# under the minimum notional. What it creates goes through Proposals::Create like any proposal, in shadow when
# the desk is, and lives until the next session's close because the check runs after this one.
class Allocation::Planner
  Verdict = Data.define(:action, :detail, :proposal, :thesis_review)

  # The expiry is worked out by the caller before any lock is taken, from Schwab's calendar only: nil when the
  # next session is not known from Schwab, and then nothing is proposed rather than an expiry guessed.
  def initialize(account, day:, expires_at:)
    @account, @day, @expires_at = account, day, expires_at
  end

  # The line's final action, written onto its drift row by the caller. Runs inside the caller's transaction,
  # which is what holds the instrument lock until the proposal and the row are both written.
  def plan(line, drift)
    return verdict(line.action) unless line.action == "reported"
    instrument = line.target.instrument or return verdict("reported", class_target: true)
    OrderProposal.lock_instrument!(account, instrument)
    return verdict("existing_proposal") if account.order_proposals.occupying.exists?(instrument: instrument)
    # A review still open after the tag came off is answered before anything mechanical happens.
    return review(line, drift) if instrument.discretionary? || account.thesis_reviews.open.exists?(instrument: instrument)
    return verdict("rejected_standing") if line.target.rejection_standing?(line.side, before: day.date)
    held = line.target.standing_hold(line.side, before: day.date) and return verdict("rejected_standing", thesis_review: held, held: true)
    return verdict("reported", sub_share: true) if line.quantity.zero?
    return verdict("reported", reason: "no min_rebalance_notional rule") unless minimum
    return verdict("reported", below_minimum: minimum.to_s("F")) if line.quantity * line.close < minimum
    return verdict("reported", reason: "the next session is not known from Schwab's calendar") unless expires_at

    proposal = Proposals::Create.call(account: account, kind: :rebalance, side: line.side, instrument: instrument, quantity: line.quantity, limit_price: line.close,
                                      origin: :allocation, expires_at: expires_at, allocation_source: drift, thesis: thesis(line))
    return verdict("reported", proposal: proposal, refused: "blocked by #{blocking_rules(proposal)}") if proposal.rejected_by_rules?
    verdict("proposed", proposal: proposal)
  rescue Proposals::Error => e
    verdict("reported", refused: e.message)
  end

  private
    attr_reader :account, :day, :expires_at

    def verdict(action, proposal: nil, thesis_review: nil, **detail) = Verdict.new(action: action, detail: detail.stringify_keys, proposal: proposal, thesis_review: thesis_review)

    # The discipline is the same, the decision is not mechanical: ask, unless the operator already said hold on this side.
    def review(line, drift)
      held = line.target.standing_hold(line.side, before: day.date) and return verdict("rejected_standing", thesis_review: held, held: true)
      verdict("thesis_review", thesis_review: ThesisReview.raise_for!(account: account, drift: drift))
    end
    def minimum = @minimum ||= RiskRule.active_for("min_rebalance_notional")&.then { |rule| BigDecimal(rule.param(:amount).to_s) }
    def thesis(line) = "Rebalance #{line.target.instrument.symbol} toward #{percent(line.target.target_weight)} of equity; at #{percent(line.weight)} after the #{day.date.strftime('%b %-d')} close."
    def percent(fraction) = "#{(fraction * 100).round(2).to_s("F")}%"
    def blocking_rules(proposal) = proposal.report.results.select(&:block?).map { |r| r.rule_type.humanize.downcase }.to_sentence
end
