# The operator's call where the desk will not act mechanically (PRD §5.12, docs/phase-2.5-plan.md §0.7, §0.8). On
# drift in a leveraged or amplified instrument: the original thesis next to the current numbers, and deploy, hold,
# or exit, where deploy and exit open the manual proposal form prefilled. On a deposit under the "ask" policy:
# deploy it now, stage it over weeks, or hold it as cash, after which the drift check does the deploying. A hold
# needs a reason. Nothing here places or sizes an order.
class ThesisReview < ApplicationRecord
  DECISIONS = { "drift" => %w[ deploy hold exit ], "deployment_ask" => %w[ deploy stage hold ] }.freeze
  PROPOSAL_KINDS = { "deploy" => "entry", "exit" => "exit" }.freeze
  NUMBERS = %w[ weight target_weight drift band close notional quantity unrealized_pnl ].freeze

  belongs_to :account
  belongs_to :instrument, optional: true # a deposit is not about one instrument
  belongs_to :cash_inflow, optional: true
  belongs_to :decided_by, class_name: "User", optional: true
  has_many :drifts, class_name: "Allocation::Drift", dependent: :restrict_with_exception

  enum :reason, { drift: "drift", deployment_ask: "deployment_ask" }, prefix: true
  enum :decision, DECISIONS.values.flatten.uniq.index_by(&:itself), prefix: true, validate: { allow_nil: true }

  scope :open, -> { where(decision: nil) }

  # The thesis the position was taken on: the open trade's, else the watchlist's, else none, said as much.
  def self.thesis_for(account, instrument)
    account.trades.open.find_by(instrument: instrument)&.thesis.presence || WatchlistItem.watching.find_by(instrument: instrument)&.thesis.presence
  end

  # One open review per instrument: a later night's drift on it refreshes the numbers on the review already waiting,
  # under the review's lock so a decision landing meanwhile is never overwritten (a decided review is not found, and
  # the caller's instrument lock keeps two raisers apart). A review that had no thesis picks one up once there is one.
  # The drift row already carries the night's numbers; the position adds what is held and its P&L.
  def self.raise_for!(account:, drift:)
    instrument = drift.target.instrument
    position = account.positions.find_by(instrument: instrument)
    context = drift.attributes.slice("as_of", "weight", "target_weight", "drift", "band", "close", "notional")
                   .merge("quantity" => position&.quantity, "unrealized_pnl" => position&.unrealized_pnl).compact.transform_values(&:to_s)
    waiting = account.thesis_reviews.open.lock.find_by(instrument: instrument)
    return waiting.tap { it.update!(context: context, thesis: it.thesis.presence || thesis_for(account, instrument)) } if waiting
    create!(account: account, instrument: instrument, reason: :drift, thesis: thesis_for(account, instrument), context: context).tap do |created|
      AuditEvent.log("thesis_review_created", actor: :system, subject: created, data: { symbol: instrument.symbol, reason: created.reason, drift: context["drift"] })
      ActiveRecord.after_all_transactions_commit { Alert.thesis_review(created) }
    end
  end

  NUMBERS.each { |key| define_method(key) { context[key]&.then { BigDecimal(it) } } }
  def as_of = context["as_of"]&.then { Date.parse(it) }
  def open? = decision.nil?
  def side = notional&.then { it.positive? ? "buy" : "sell" }
  def proposal_kind = reason_drift? ? PROPOSAL_KINDS[decision] : nil
  def decisions = DECISIONS.fetch(reason)
  def label = reason_drift? ? instrument.symbol : cash_inflow.label

  # A hold needs a reason; deploy and exit lead to a proposal the operator writes, so the reason is optional. A form
  # shown numbers the nightly refresh has since replaced is refused, so a hold always stands on what was seen.
  def decide!(decision:, user:, reason: nil, seen_as_of: nil, weeks: nil)
    decided = decision.to_s
    raise ArgumentError, "choose #{decisions.to_sentence(last_word_connector: ", or ", two_words_connector: " or ")}" unless decisions.include?(decided)
    raise ArgumentError, "a hold needs a reason" if decided == "hold" && reason.blank?
    transaction do
      lock!
      raise ActiveRecord::StaleObjectError.new(self, "decide") unless open?
      raise ActiveRecord::StaleObjectError.new(self, "refreshed") if seen_as_of.present? && seen_as_of.to_s != context["as_of"]
      update!(decision: decided, decision_reason: reason.presence, decided_at: Time.current, decided_by: user)
      AuditEvent.log("thesis_review_decided", actor: :human, user: user, subject: self, reason: decision_reason, data: { subject: label, decision: decided })
      cash_inflow.answer!(decided, user: user, weeks: weeks, reason: decision_reason) if reason_deployment_ask?
    end
    self
  end
end
