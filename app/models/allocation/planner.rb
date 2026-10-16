# The one thing that turns drift and new cash into proposals (docs/phase-2.5-plan.md §0.6, §0.8). For drift outside
# a band it decides, under the account-and-instrument lock Proposals::Create also takes, whether the desk may
# propose: never on a class (no instrument to order), never on a leveraged or amplified instrument or one with a
# review still open (the operator is asked instead), never beside a waiting or unresolved proposal, never while a
# rejection or a hold stands, never under the minimum notional. New cash goes the same way and is held to the same
# answers. What it creates goes through Proposals::Create like any proposal, in shadow when the desk is, and lives
# until the next session's close because the check runs after this one.
class Allocation::Planner
  Verdict = Data.define(:action, :detail, :proposal, :thesis_review)

  # What a share of new cash came to tonight. Buying, or a share that cannot or should not be bought (too small,
  # not short of its target, held or rejected by the operator, a class or a leveraged name), settles it and leaves
  # that share as cash; anything passing (unsettled cash, a waiting proposal, no price, blocked, an error) defers it.
  Outcome = Data.define(:target, :result, :final) do
    def proposed? = result == "proposed"
    def deferred? = !final
  end

  def self.error_verdict(error) = Verdict.new(action: "reported", detail: { "error" => error.message.truncate(200) }, proposal: nil, thesis_review: nil)

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
    held = line.target.standing_hold(line.side, before: day.date) and return verdict("rejected_standing", thesis_review: held, held: true)
    # A review still open after the tag came off is answered before anything mechanical happens.
    return verdict("thesis_review", thesis_review: ThesisReview.raise_for!(account: account, drift: drift)) if asking_about?(instrument)
    return verdict("reported", committed: true) if line.side == "buy" && deploying? # one writer for buys at a time
    return verdict("rejected_standing") if line.target.rejection_standing?(line.side, before: day.date)
    return verdict("reported", sub_share: true) if line.quantity.zero?
    return verdict("reported", reason: "no min_rebalance_notional rule") unless minimum
    return verdict("reported", below_minimum: minimum.to_s("F")) if line.quantity * line.close < minimum
    return verdict("reported", reason: "the next session is not known from Schwab's calendar") unless expires_at

    proposal = Proposals::Create.call(account: account, kind: :rebalance, side: line.side, instrument: instrument, quantity: line.quantity, limit_price: line.close,
                                      origin: :allocation, expires_at: expires_at, allocation_source: drift, thesis: thesis(line))
    return verdict("reported", proposal: proposal, refused: "blocked by #{blocking_rules(proposal.report)}") if proposal.rejected_by_rules?
    verdict("proposed", proposal: proposal)
  rescue Proposals::Error => e
    verdict("reported", refused: e.message)
  end

  # New cash, split pro-rata over every active target's weight and each share capped at what tonight's drift row
  # says that target is short, so nothing is bought that the next check would sell. A class's share, a leveraged
  # name's, and whatever the caps leave stay cash. Whole shares at tonight's close, spent only from settled cash
  # not already claimed. Returns an outcome per target; :halted while entries are halted, which waits without
  # counting against the deposit; or nil when tonight cannot place anything (no calendar, no target).
  def deploy(source, amount)
    return :halted unless SystemSettings.instance.entries_allowed?
    targets = Allocation::Target.active.includes(instrument: :tags).order(:id).to_a
    whole = targets.sum(&:target_weight)
    return nil unless expires_at && whole.positive?
    drifts = Allocation::Drift.where(as_of: day.date, target: targets).not_action_unavailable.index_by(&:allocation_target_id)
    targets.map do |target|
      share = (amount * target.target_weight / whole).round(2, BigDecimal::ROUND_DOWN) # rounded down: the shares never sum past the amount
      Outcome.new(target: target.label, **deploy_to(source, target, drifts[target.id], share))
    end
  end

  private
    attr_reader :account, :day, :expires_at

    def deploying? = defined?(@deploying) ? @deploying : (@deploying = account.cash_inflows.committing.exists?)
    def asking_about?(instrument) = instrument.discretionary? || account.thesis_reviews.open.exists?(instrument: instrument)

    def deploy_to(source, target, drift, share)
      instrument = target.instrument or return settle("a class: its share stays cash")
      return settle("leveraged, amplified, or under review: its share stays cash") if asking_about?(instrument)
      return settle("your hold stands: its share stays cash") if target.hold_standing?("buy", before: day.date)
      return settle("your rejection stands: its share stays cash") if target.rejection_standing?("buy", before: day.date)
      return defer("no price tonight") unless drift&.close
      share = [ share, drift.notional.to_d ].min
      return settle("not short of its target") unless share.positive?
      quantity = (share / drift.close).floor
      return settle("under one share") if quantity.zero?
      return defer("no min_rebalance_notional rule") unless minimum
      return settle("under the minimum") if quantity * drift.close < minimum
      return defer("waiting for settled cash") unless spend(quantity * drift.close)
      propose_deployment(source, target, drift.close, share, quantity).tap { |outcome| refund(quantity * drift.close) unless outcome[:result] == "proposed" }
    end

    # A blocked buy is retried, not left behind as a row and an alert each night; the halt it asked for is engaged
    # after the rollback, as the approve path does, so a tripped rule is never lost with the row.
    def propose_deployment(source, target, close, share, quantity)
      blocked = nil
      proposed = OrderProposal.transaction(requires_new: true) do
        OrderProposal.lock_instrument!(account, target.instrument)
        next defer("a proposal is already waiting") if account.order_proposals.occupying.exists?(instrument: target.instrument)
        proposal = Proposals::Create.call(account: account, kind: :rebalance, side: :buy, instrument: target.instrument, quantity: quantity, limit_price: close,
                                          origin: :allocation, expires_at: expires_at, allocation_source: source, context: deployment_context(source, share),
                                          thesis: "Deploy #{ActiveSupport::NumberHelper.number_to_currency(share)} of #{source.label} into #{target.label}, a #{target.target_percent_label} target.")
        if proposal.rejected_by_rules?
          blocked = proposal.report
          raise ActiveRecord::Rollback
        end
        { result: "proposed", final: true }
      end
      return proposed if proposed
      Guardrails.engage_halts!(blocked)
      defer("blocked by #{blocking_rules(blocked)}")
    rescue StandardError => e # one target's failure defers its share, never the night
      Rails.error.report(e, handled: true, context: { planner: "deploy", target: target.id }) unless e.is_a?(Proposals::Error)
      defer("not proposed: #{e.message.truncate(120)}")
    end

    def settle(result) = { result: result, final: true }
    def defer(result) = { result: result, final: false }

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
    def minimum = defined?(@minimum) ? @minimum : (@minimum = RiskRule.min_rebalance_notional)
    def thesis(line) = "Rebalance #{line.target.instrument.symbol} toward #{line.target.target_percent_label} of equity; at #{(line.weight * 100).round(2).to_s("F")}% after the #{day.date.strftime('%b %-d')} close."
    def blocking_rules(report) = report.results.select(&:block?).map { |r| r.rule_type.humanize.downcase }.to_sentence
end
