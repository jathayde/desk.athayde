# A guardrail as data (docs/phase-2-plan.md §0.8): one active row per type and setup, edited by superseding,
# never in place, so every proposal's results point at the exact version that judged it.
class RiskRule < ApplicationRecord
  TYPES = %w[ max_risk_per_trade max_positions max_position_exposure max_sector_exposure daily_loss_halt max_drawdown_halt
              settled_cash earnings_blackout wash_sale notional_cap stop_collar ].freeze

  belongs_to :setup, optional: true
  belongs_to :superseded_by, class_name: "RiskRule", optional: true
  belongs_to :changed_by, class_name: "User", optional: true

  enum :mode, { block: "block", warn: "warn" }, prefix: true

  validates :rule_type, inclusion: { in: TYPES }
  validates :params, presence: true

  scope :active, -> { where(active: true) }

  def self.active_for(rule_type, setup: nil) = active.find_by(rule_type: rule_type, setup: setup) || (setup && active.find_by(rule_type: rule_type, setup: nil))

  # The next version of this rule, superseding this one, in one transaction and one audit row.
  def supersede!(params:, user:, mode: self.mode, note: nil)
    transaction do
      update!(active: false) # first, so the one-active index admits the successor
      successor = self.class.create!(rule_type: rule_type, setup: setup, params: params, mode: mode, note: note, version: version + 1, changed_by: user)
      update!(superseded_by: successor)
      AuditEvent.log("rule_changed", actor: :human, user: user, subject: successor, reason: note, data: { rule_type: rule_type, setup: setup&.name, before: self.params, after: params, version: successor.version })
      successor
    end
  end

  def param(name) = params.fetch(name.to_s) { raise KeyError, "#{rule_type} rule has no #{name}" }
end
