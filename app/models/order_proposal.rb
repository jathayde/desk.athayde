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
  has_many :orders, dependent: :restrict_with_exception
  has_many :submission_attempts, dependent: :restrict_with_exception
  has_one :trade, dependent: :restrict_with_exception

  enum :kind, { entry: "entry", exit: "exit", stop_adjustment: "stop_adjustment" }, prefix: true
  enum :origin, { agent: "agent", human: "human" }
  enum :side, { buy: Schwab::Order::BUY, sell: Schwab::Order::SELL }
  enum :child_action, { cancel_stop: "cancel_stop", replace_stop: "replace_stop" }, prefix: true
  enum :status, {
    proposed: "proposed", validated: "validated", rejected_by_rules: "rejected_by_rules", rejected: "rejected", expired: "expired",
    submitting: "submitting", submitted: "submitted", submission_unknown: "submission_unknown", submission_failed: "submission_failed",
    filled: "filled", cancelled: "cancelled"
  }

  TERMINAL = %w[ rejected_by_rules rejected expired submission_failed filled cancelled ].freeze
  APPROVABLE = %w[ validated ].freeze
  UNRESOLVED = %w[ submitting submission_unknown ].freeze # locks the instrument for every other proposal
  BROKER_OUTCOMES = %w[ filled cancelled ].freeze

  scope :unresolved, -> { where(status: UNRESOLVED) }
  scope :queue, -> { where(status: %w[ proposed validated submission_unknown ]).order(created_at: :desc) }
  scope :expiring, -> { where(status: %w[ proposed validated ]).where(expires_at: ..Time.current) }
  scope :stale_submitting, ->(older_than) { submitting.where(updated_at: ..older_than.ago) }

  validates :quantity, numericality: { greater_than: 0 }, allow_nil: true

  def self.instrument_locked?(instrument) = unresolved.where(instrument: instrument).exists?

  def terminal? = TERMINAL.include?(status)
  def approvable? = APPROVABLE.include?(status)
  # Everything the approver must acknowledge: warnings and the rules that could not be checked.
  def warnings = guardrail_results.select { |_, r| r["outcome"].in?(%w[ warn unavailable ]) }.keys
  def live_attempt = submission_attempts.live.first

  # ---- transitions, each a row of the table, each one audit row, each under the row lock ----------

  def evaluate!(report)
    transition!(from: %w[ proposed ], to: report.blocked? ? :rejected_by_rules : :validated, event: "proposal_evaluated",
                attributes: { guardrail_results: report.to_h, evaluated_at: Time.current }, data: { blocked: report.blocked?, warnings: report.warnings })
  end

  def reject!(user:, reason:)
    raise ArgumentError, "a rejection needs a reason" if reason.blank?
    transition!(from: APPROVABLE, to: :rejected, event: "proposal_rejected", user: user, reason: reason,
                attributes: { decided_at: Time.current, decided_by: user, rejection_reason: reason })
  end

  def expire!
    transition!(from: %w[ proposed validated ], to: :expired, event: "proposal_expired")
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
    outcome!(attempt, from: %w[ submitting ], to: :submitted, event: "would_have_submitted", attributes: { submitted_at: Time.current }) do
      attempt.update!(outcome: :would_have_submitted)
    end
  end

  def record_submitted!(attempt, broker_order_id:)
    outcome!(attempt, from: %w[ submitting ], to: :submitted, event: "proposal_submitted",
             attributes: { submitted_at: Time.current, broker_order_id: broker_order_id }, data: { broker_order_id: broker_order_id }) do
      attempt.update!(outcome: :submitted, broker_order_id: broker_order_id)
    end
  end

  def record_unknown!(attempt, error:)
    outcome!(attempt, from: %w[ submitting ], to: :submission_unknown, event: "submission_unknown", reason: error) do
      attempt.update!(outcome: :unknown, response: { "error" => error })
    end
  end

  # Schwab refused the payload (a 4xx): the operator reads the error and may re-propose.
  def record_rejected!(attempt, error:)
    outcome!(attempt, from: %w[ submitting ], to: :submission_failed, event: "submission_failed", reason: error) do
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
