# The one thing that turns drift and new cash into proposals (docs/phase-2.5-plan.md §0.6, §0.8). For each line outside its band it
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
    return verdict("reported", committed: true) if line.side == "buy" && deploying? # one writer for buys at a time
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

  # What a share of new cash came to tonight. Only buying, or a share too small to buy, settles it; anything
  # else (unsettled cash, a halt, a waiting proposal, no price, an error) is deferred and the cash tried again.
  Outcome = Data.define(:target, :result, :final) do
    def proposed? = result == "proposed"
    def deferred? = !final
  end

  # New cash, split pro-rata to the active instrument targets' weights (classes and leveraged or amplified
  # instruments left out), whole shares at tonight's close, spent only from settled cash not already claimed,
  # tonight's earlier buys included. Returns an outcome per target, or nil when tonight cannot place anything at
  # all (no calendar, no target), so the caller leaves the cash to try again.
  def deploy(source, amount)
    targets = Allocation::Target.active.includes(instrument: :tags).reject { |target| target.instrument.nil? || target.instrument.discretionary? }
    whole = targets.sum(&:target_weight)
    return nil unless expires_at && whole.positive?
    closes = Allocation::Drift.where(as_of: day.date, target: targets).not_action_unavailable.where.not(close: nil).pluck(:allocation_target_id, :close).to_h
    targets.map do |target|
      share = (amount * target.target_weight / whole).round(2, BigDecimal::ROUND_DOWN) # rounded down: the shares never sum past the amount
      Outcome.new(target: target.label, **deploy_to(source, target, closes[target.id], share))
    end
  end

  private
    attr_reader :account, :day, :expires_at

    def deploying? = defined?(@deploying) ? @deploying : (@deploying = account.cash_inflows.committing.exists?)

    def deploy_to(source, target, close, share)
      return { result: "no price tonight", final: false } unless close
      quantity = (share / close).floor
      return { result: "under one share", final: true } if quantity.zero?
      return { result: "no min_rebalance_notional rule", final: false } unless minimum
      return { result: "under the minimum", final: true } if quantity * close < minimum
      return { result: "waiting for settled cash", final: false } unless spend(quantity * close)
      propose_deployment(source, target, close, share, quantity).tap { |outcome| refund(quantity * close) unless outcome[:result] == "proposed" }
    end

    def propose_deployment(source, target, close, share, quantity)
      OrderProposal.transaction(requires_new: true) do
        OrderProposal.lock_instrument!(account, target.instrument)
        next { result: "a proposal is already waiting", final: false } if account.order_proposals.occupying.exists?(instrument: target.instrument)
        proposal = Proposals::Create.call(account: account, kind: :rebalance, side: :buy, instrument: target.instrument, quantity: quantity, limit_price: close,
                                          origin: :allocation, expires_at: expires_at, allocation_source: source, context: deployment_context(source, share),
                                          thesis: "Deploy #{ActiveSupport::NumberHelper.number_to_currency(share)} of #{source.label} into #{target.label}, a #{percent(target.target_weight)} target.")
        raise ActiveRecord::Rollback if proposal.rejected_by_rules? # a blocked buy is retried, not left behind as a row and an alert each night
        { result: "proposed", final: true }
      end || { result: "blocked by the rules", final: false }
    rescue StandardError => e # one target's failure defers its share, never the night
      Rails.error.report(e, handled: true, context: { planner: "deploy", target: target.id }) unless e.is_a?(Proposals::Error)
      { result: "not proposed: #{e.message.truncate(120)}", final: false }
    end

    # Settled cash not yet claimed, less every buy proposed tonight: nil (unknown) spends nothing.
    def spend(cost)
      @cash = Guardrails::Context.new(account).projected_settled_cash unless defined?(@cash)
      return false if @cash.nil? || cost > @cash
      @cash -= cost
    end

    def refund(cost) = @cash += cost

    # The base rates the operator wrote down, frozen as they read tonight, never computed.
    def deployment_context(source, share) = { "source" => source.label, "share" => share.to_s, "notes" => deployment_notes }
    def deployment_notes = defined?(@notes) ? @notes : (@notes = Memory::Repo.configured.text("deployment.md"))

    def verdict(action, proposal: nil, thesis_review: nil, **detail) = Verdict.new(action: action, detail: detail.stringify_keys, proposal: proposal, thesis_review: thesis_review)

    # The discipline is the same, the decision is not mechanical: ask, unless the operator already said hold on this side.
    def review(line, drift)
      held = line.target.standing_hold(line.side, before: day.date) and return verdict("rejected_standing", thesis_review: held, held: true)
      verdict("thesis_review", thesis_review: ThesisReview.raise_for!(account: account, drift: drift))
    end
    def minimum = defined?(@minimum) ? @minimum : (@minimum = RiskRule.min_rebalance_notional)
    def thesis(line) = "Rebalance #{line.target.instrument.symbol} toward #{percent(line.target.target_weight)} of equity; at #{percent(line.weight)} after the #{day.date.strftime('%b %-d')} close."
    def percent(fraction) = "#{(fraction * 100).round(2).to_s("F")}%"
    def blocking_rules(proposal) = proposal.report.results.select(&:block?).map { |r| r.rule_type.humanize.downcase }.to_sentence
end
