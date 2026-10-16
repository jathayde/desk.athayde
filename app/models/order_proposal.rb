# One proposed order and its whole life (docs/phase-2-state-table.md). Sizing and the collar are frozen at
# creation; the approve gesture is the submission; nothing leaves the submission path by hand. Every
# transition locks the row, re-reads the state, and writes its audit row in the same transaction.
class OrderProposal < ApplicationRecord
  class IllegalTransition < StandardError; end

  belongs_to :account
  belongs_to :instrument
  belongs_to :target_order, class_name: "Order", optional: true
  belongs_to :user, optional: true
  belongs_to :decided_by, class_name: "User", optional: true
  belongs_to :setup, optional: true
  belongs_to :parent_proposal, class_name: "OrderProposal", optional: true
  belongs_to :allocation_source, polymorphic: true, optional: true # the drift row (later the inflow or tranche) an allocation proposal came from
  has_many :orders, dependent: :restrict_with_exception
  has_many :submission_attempts, dependent: :restrict_with_exception
  has_one :trade, dependent: :restrict_with_exception

  enum :kind, { entry: "entry", exit: "exit", stop_adjustment: "stop_adjustment", rebalance: "rebalance" }, prefix: true
  enum :origin, { agent: "agent", human: "human", allocation: "allocation" }
  enum :side, { buy: Schwab::Order::BUY, sell: Schwab::Order::SELL }
  enum :child_action, { cancel_stop: "cancel_stop", replace_stop: "replace_stop" }, prefix: true
  enum :status, {
    proposed: "proposed", validated: "validated", rejected_by_rules: "rejected_by_rules", rejected: "rejected", expired: "expired",
    submitting: "submitting", submitted: "submitted", submission_unknown: "submission_unknown", submission_failed: "submission_failed",
    filled: "filled", cancelled: "cancelled"
  }

  TERMINAL = %w[ rejected_by_rules rejected expired submission_failed filled cancelled ].freeze
  STALE_SUBMITTING = 5.minutes # past two writes at their timeouts, a refresh, and slack: the worker died
  LOOK_GAP = 15.minutes # an unknown row nobody has looked at for this long gets a reconcile enqueued again
  APPROVABLE = %w[ validated ].freeze
  UNRESOLVED = %w[ submitting submission_unknown ].freeze # locks the instrument for every other proposal
  COMMITTED = %w[ validated submitting submission_unknown submitted ].freeze # the desk has committed to these: they claim cash and count as positions
  AT_BROKER = %w[ submitting submission_unknown submitted ].freeze # at Schwab, or maybe at Schwab
  QUEUE = %w[ proposed validated submission_unknown ].freeze # what the operator still has to deal with
  BROKER_OUTCOMES = %w[ filled cancelled ].freeze

  STATUS_LABELS = { "proposed" => "evaluating", "validated" => "waiting for you", "rejected_by_rules" => "rejected by rules", "rejected" => "rejected",
                    "expired" => "expired", "submitting" => "submitting", "submitted" => "submitted", "submission_unknown" => "submission unknown",
                    "submission_failed" => "not placed", "filled" => "filled", "cancelled" => "cancelled" }.freeze

  scope :pending, -> { where(status: %w[ proposed validated ]) }
  scope :unresolved, -> { where(status: UNRESOLVED) }
  # Waiting, or approved and not yet filled or cancelled (a shadow approval awaiting hand placement included): the
  # instrument is spoken for, and the allocation planner steps aside.
  scope :occupying, -> { where(status: %w[ proposed ] + COMMITTED) }
  scope :committed, -> { where(status: COMMITTED) }
  scope :at_broker, -> { where(status: AT_BROKER) }
  scope :decided, -> { where.not(status: QUEUE) }
  scope :queue, -> { where(status: QUEUE).order(created_at: :desc) }
  scope :expiring, -> { where(status: %w[ proposed validated ]).where(expires_at: ..Time.current) }
  # A shadow approval the operator still has to place by hand: the phase's central concept, named once.
  scope :awaiting_hand_placement, -> { submitted.where(shadow: true, broker_order_id: nil) }
  scope :stale_submitting, ->(older_than) { submitting.where(updated_at: ..older_than.ago) }

  validates :quantity, numericality: { greater_than: 0 }, allow_nil: true
  validates :quantity, presence: true, unless: :kind_entry? # an entry may be unsized (and blocked); a sell of nothing is not a proposal

  def self.instrument_locked?(instrument) = unresolved.where(instrument: instrument).exists?

  # A submitting row older than the call's timeouts is a worker that died mid-submission. Shadow rows finish as
  # what they were going to be; real rows become unknown and the reconcile job looks. Never back to validated.
  def self.sweep_submitting!
    stale_submitting(STALE_SUBMITTING).find_each do |proposal|
      attempt = proposal.submission_attempts.pending.first or next
      if proposal.shadow?
        proposal.record_shadow!(attempt)
      else
        proposal.record_unknown!(attempt, error: "left submitting")
        Submission::ReconcileJob.perform_later(proposal)
      end
    rescue IllegalTransition
      next # the worker answered between the query and the lock; its answer stands, and the rest of the sweep goes on
    end
  end

  # An unknown row the reconcile job has not looked at in a while (its job lost, its retries spent) is looked at again.
  def self.redrive_unknown!
    submission_unknown.joins(:submission_attempts).merge(SubmissionAttempt.unknown.unlooked_at_since(LOOK_GAP.ago)).distinct.find_each do |proposal|
      Submission::ReconcileJob.perform_later(proposal)
    end
  end

  # One writer at a time per account and instrument, held until the caller's transaction ends: Proposals::Create
  # and the allocation planner both take it before checking that nothing else is waiting on the instrument.
  def self.lock_instrument!(account, instrument) = connection.execute(sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", account.id, instrument.id ]))

  # What a proposal does, not what it is called (docs/phase-2.5-plan.md §0.5): a rebalance buy opens exposure like
  # an entry but carries no stop; a rebalance sell reduces a position like an exit. The class form lets
  # Proposals::Create refuse a halted desk before its draft reads candles.
  def self.opens_exposure?(kind, side) = kind.to_s == "entry" || (kind.to_s == "rebalance" && side.to_s == "buy")
  def opens_exposure? = self.class.opens_exposure?(kind, side)
  def reduces_position? = kind_exit? || (kind_rebalance? && sell?)
  def requires_bracket? = kind_entry?
  def kind_phrase = kind_exit? ? "an exit" : kind_rebalance? ? "a rebalance #{side}" : "a #{kind.humanize.downcase}"
  def audit_actor = allocation? ? :system : origin.to_sym

  def approvable? = APPROVABLE.include?(status)
  # The stored evaluation, read through the same object the evaluator produced: one implementation of what
  # counts as a warning, whichever side of the jsonb it is read from.
  def report = Guardrails::Report.load(guardrail_results)
  delegate :warnings, :needs_override?, to: :report
  def live_attempt = submission_attempts.live.first
  def awaiting_hand_placement? = submitted? && shadow? && broker_order_id.nil?
  def latest_attempt = submission_attempts.order(:id).last
  # What the operator reads on a failed or unresolved submission: Schwab's answer, or the orders that could each be it.
  def failure_reason = submission_failed? ? latest_attempt&.error : nil
  def ambiguous_orders = submission_unknown? ? Array(latest_attempt&.ambiguous_order_ids) : []

  # The approve gesture: transaction one, then the shadow or real branch (Submission::Submit).
  def approve_and_submit!(user:, acknowledged: [], override_reason: nil) = Submission::Submit.call(self, user: user, acknowledged: acknowledged, override_reason: override_reason)

  # ---- transitions, each a row of the table, each one audit row, each under the row lock ----------

  # The evaluation's writer: stores the report and engages any halt its rules asked for, in the same transaction.
  def evaluate!(report)
    transaction do
      Guardrails.engage_halts!(report)
      transition!(from: %w[ proposed ], to: report.blocked? ? :rejected_by_rules : :validated, event: "proposal_evaluated",
                  attributes: { guardrail_results: report.to_h, evaluated_at: Time.current }, data: { blocked: report.blocked?, warnings: report.warnings })
    end
  end

  def reject!(user:, reason:)
    raise ArgumentError, "a rejection needs a reason" if reason.blank?
    transition!(from: APPROVABLE, to: :rejected, event: "proposal_rejected", user: user, reason: reason,
                attributes: { decided_at: Time.current, decided_by: user, rejection_reason: reason })
  end

  def expire!
    transition!(from: %w[ proposed validated ], to: :expired, event: "proposal_expired")
  end

  # The one way a proposal is named in prose: emails, banners, the recap, the journal. An unsized entry has no number to show.
  def label = [ side.upcase, quantity&.to_s("F")&.sub(/\.0+\z/, ""), instrument.symbol ].compact.join(" ")
  def priced_label = "#{label} @ #{ActiveSupport::NumberHelper.number_to_currency(limit_price)}"
  def cost = quantity.to_d * limit_price.to_d

  def status_label
    return "approved, place by hand" if awaiting_hand_placement?
    return "submission unknown, ambiguous" if ambiguous_orders.any?
    STATUS_LABELS.fetch(status)
  end

  # Transaction one of the submission: the approval, the state, and the attempt row commit together, or not at all.
  # One live submission per instrument: refused here in words, and by the database's partial unique index.
  def start_submission!(user:, acknowledged:, override_reason:, payload:, shadow:)
    transaction do
      raise IllegalTransition, "#{instrument.symbol} has a submission still unresolved" if self.class.unresolved.where(instrument_id: instrument_id).where.not(id: id).exists?
      transition!(from: APPROVABLE, to: :submitting, event: "proposal_approved", user: user, reason: override_reason,
                  attributes: { decided_at: Time.current, decided_by: user, acknowledged_warnings: acknowledged, override_reason: override_reason, shadow: shadow },
                  data: { acknowledged: acknowledged, shadow: shadow })
      submission_attempts.create!(attempted_at: Time.current, payload: payload, outcome: :pending).tap do
        AuditEvent.log("proposal_submitting", actor: :human, user: user, subject: self)
      end
    end
  end

  # Transaction two: what Schwab, or shadow mode, answered. The state moves first; the attempt follows.
  def record_shadow!(attempt)
    outcome!(attempt, from: %w[ submitting ], to: :submitted, event: "would_have_submitted", attributes: { submitted_at: Time.current }, data: { payload: attempt.payload }) do
      attempt.update!(outcome: :would_have_submitted)
    end
  end

  # A late answer with the id is authoritative: after the sweep called the row unknown, and even after the
  # reconcile job called it not placed, since the id is the last fact and a working order must be on the row
  # the sync links and the fill reaches. That second case is mailed: the operator was told nothing was placed.
  def record_submitted!(attempt, broker_order_id:)
    late = attempt.reload.not_placed? # the worker's copy predates the sweep and the reconcile job
    outcome!(attempt, from: late ? %w[ submission_failed ] : %w[ submitting submission_unknown ], to: :submitted, event: "proposal_submitted",
             reason: late ? "late answer after not placed" : nil,
             attributes: { submitted_at: Time.current, broker_order_id: broker_order_id }, data: { broker_order_id: broker_order_id, late: late }) do
      attempt.update!(outcome: :submitted, broker_order_id: broker_order_id)
    end
    ActiveRecord.after_all_transactions_commit { Alert.late_submission(self) } if late
    self
  end

  # Unknown is the one outcome that mails at once: the operator must not touch the instrument until it is
  # resolved. A maybe-sent answer arriving after the reconcile job called the row not placed reopens it: the
  # job's verdict was about an order it could not yet see, and the row must go back to being looked at.
  def record_unknown!(attempt, error:)
    late = attempt.reload.not_placed?
    outcome!(attempt, from: late ? %w[ submission_failed ] : %w[ submitting ], to: :submission_unknown, event: "submission_unknown", reason: error, data: { late: late }) do
      attempt.update!(outcome: :unknown, response: { "error" => error }, first_absence_at: nil)
    end
    ActiveRecord.after_all_transactions_commit { Alert.submission_unknown(self) } # the caller enqueues the look
    self
  end

  # Schwab refused the payload (a 4xx): the operator reads the error and may re-propose. Final even after the
  # sweep called the row unknown: the one call was answered, and the reconcile job's first line then exits.
  def record_rejected!(attempt, error:)
    outcome!(attempt, from: %w[ submitting submission_unknown ], to: :submission_failed, event: "submission_failed", reason: error) do
      attempt.update!(outcome: :failed, response: { "error" => error })
    end
  end

  # The reconcile job confirmed twice, ten minutes apart, that nothing was placed.
  def record_not_placed!(attempt)
    outcome!(attempt, from: %w[ submission_unknown ], to: :submission_failed, event: "submission_failed", reason: "confirmed not placed") do
      attempt.update!(outcome: :not_placed)
    end
  end

  # The reconcile job found the order an unknown submission placed.
  def record_reconciled!(attempt, order:)
    outcome!(attempt, from: %w[ submission_unknown ], to: :submitted, event: "submission_reconciled",
             attributes: { submitted_at: Time.current, broker_order_id: order.broker_order_id }, data: { broker_order_id: order.broker_order_id }) do
      attempt.update!(outcome: :submitted, broker_order_id: order.broker_order_id, reconciled_order: order, reconciled_at: Time.current)
    end
  end

  # A shadowed submission matched to the order the operator placed by hand: no state change, one audit row.
  def link_shadow_order!(attempt, order:)
    raise IllegalTransition, "#{status} is not a shadowed submission" unless submitted? && shadow? && attempt.would_have_submitted?
    transaction do
      attempt.update!(reconciled_order: order, reconciled_at: Time.current, broker_order_id: order.broker_order_id)
      update!(broker_order_id: order.broker_order_id)
      AuditEvent.log("submission_reconciled", actor: :system, subject: self, data: { broker_order_id: order.broker_order_id, shadow: true })
    end
    self
  end

  # Written only by the orders sync, and only to the two states the broker can put an order in.
  def record_broker_outcome!(status)
    status = status.to_s
    raise ArgumentError, "#{status} is not a broker outcome" unless BROKER_OUTCOMES.include?(status)
    transition!(from: %w[ submitted ], to: status, event: "proposal_#{status}")
    ActiveRecord.after_all_transactions_commit { Alert.fill_or_cancel(self) }
    self
  end

  private
    def outcome!(attempt, from:, to:, event:, attributes: {}, reason: nil, data: {})
      raise ArgumentError, "attempt #{attempt.id} belongs to another proposal" unless attempt.order_proposal_id == id
      transaction do
        transition!(from: from, to: to, event: event, attributes: attributes, reason: reason, data: data)
        yield
      end
      self
    end

    # Lock, re-read, refuse from the wrong state, write, audit: one transaction, never a stale instance's guess.
    def transition!(from:, to:, event:, attributes: {}, user: nil, reason: nil, data: {})
      with_lock do
        raise IllegalTransition, "proposal #{id} cannot go from #{status} to #{to}" unless from.include?(status)
        update!(attributes.merge(status: to))
        AuditEvent.log(event, actor: user ? :human : :system, user: user, subject: self, reason: reason, data: data)
      end
      self
    end
end
