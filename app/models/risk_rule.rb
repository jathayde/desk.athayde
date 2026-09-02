# A guardrail as data (docs/phase-2-plan.md §0.8): one active row per type and setup, edited by superseding,
# never in place, so every proposal's results point at the exact version that judged it.
class RiskRule < ApplicationRecord
  TYPES = %w[ max_risk_per_trade max_positions max_position_exposure max_sector_exposure daily_loss_halt max_drawdown_halt
              earnings_blackout wash_sale notional_cap stop_collar ].freeze
  REQUIRED_PARAMS = { "max_risk_per_trade" => %w[ percent ], "max_positions" => %w[ count ], "max_position_exposure" => %w[ percent ],
                      "daily_loss_halt" => %w[ percent ], "max_drawdown_halt" => %w[ percent ], "notional_cap" => %w[ per_order per_day ] }.freeze

  # Raised when a halt is engaged and no override reason was given: the editor is locked, by design, so a
  # rule cannot be loosened in the heat of the moment without saying why.
  class Locked < StandardError; end

  belongs_to :setup, optional: true
  belongs_to :superseded_by, class_name: "RiskRule", optional: true
  belongs_to :changed_by, class_name: "User", optional: true

  enum :mode, { block: "block", warn: "warn" }, prefix: true

  validates :rule_type, inclusion: { in: TYPES }
  validate :required_params_present

  scope :active, -> { where(active: true) }

  def self.active_for(rule_type, setup: nil) = active.find_by(rule_type: rule_type, setup: setup) || (setup && active.find_by(rule_type: rule_type, setup: nil))

  # The next version of this rule, superseding this one, in one transaction and one audit row. Under this row's
  # lock and the settings lock, so two edits cannot both mint version n+1 and a halt landing mid-edit still locks.
  def supersede!(params:, user:, mode: nil, note: nil, override_reason: nil)
    override = override_reason.to_s.strip
    transaction do
      lock!
      raise ActiveRecord::StaleObjectError.new(self, "supersede") unless active?
      raise Locked, "a halt is engaged: say why you are editing anyway" if SystemSettings.instance.lock!.halted? && override.blank?
      update!(active: false) # first, so the one-active index admits the successor
      successor = self.class.create!(rule_type: rule_type, setup: setup, params: params, mode: mode.presence || self.mode, version: version + 1, changed_by: user,
                                     note: [ note.presence, ("override during halt: #{override}" if override.present?) ].compact.join(" · ").presence)
      update!(superseded_by: successor)
      AuditEvent.log("rule_changed", actor: :human, user: user, subject: successor, reason: successor.note,
                     data: { rule_type: rule_type, setup: setup&.name, before: { params: self.params, mode: self.mode }, after: { params: successor.params, mode: successor.mode },
                             version: successor.version, during_halt: override.present?, override_reason: override.presence })
      successor
    end
  end

  def param(name) = params.fetch(name.to_s) { raise KeyError, "#{rule_type} rule has no #{name}" }
  def param_keys = (params.keys + Array(REQUIRED_PARAMS[rule_type])).uniq
  def mode_choosable? = rule_type == "wash_sale"

  # Whether this is the row the evaluator would pick for the proposal: the setup's own row wins, the global row
  # is the fallback for setups without one.
  def applies_to?(proposal) = self.class.active_for(rule_type, setup: proposal.setup) == self

  private
    def required_params_present
      missing = REQUIRED_PARAMS.fetch(rule_type.to_s, []).reject { |key| params.to_h[key].present? }
      errors.add(:params, "is missing #{missing.to_sentence}") if missing.any?
    end
end
