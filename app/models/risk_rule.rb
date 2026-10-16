# A guardrail as data (docs/phase-2-plan.md §0.8): one active row per scope, type, and setup, edited by superseding,
# never in place, so every proposal's results point at the exact version that judged it. Trade rules judge one
# order; book rules (docs/phase-2.5-plan.md §0.1) judge the whole book and never appear in a proposal's results.
class RiskRule < ApplicationRecord
  include Superseding

  TRADE_TYPES = %w[ max_risk_per_trade max_positions max_position_exposure max_sector_exposure daily_loss_halt max_drawdown_halt
                    earnings_blackout wash_sale notional_cap stop_collar ].freeze
  BOOK_TYPES = %w[ rebalance_band min_rebalance_notional correlation_threshold cash_drag_weeks ].freeze
  REQUIRED_PARAMS = { "max_risk_per_trade" => %w[ percent ], "max_positions" => %w[ count ], "max_position_exposure" => %w[ percent ],
                      "daily_loss_halt" => %w[ percent ], "max_drawdown_halt" => %w[ percent ], "notional_cap" => %w[ per_order per_day ],
                      "rebalance_band" => %w[ percent ], "min_rebalance_notional" => %w[ amount ], "correlation_threshold" => %w[ value window_days ],
                      "cash_drag_weeks" => %w[ weeks ] }.freeze

  belongs_to :setup, optional: true

  enum :mode, { block: "block", caution: "caution" }, prefix: true # caution: the outcome the approver acknowledges
  enum :scope, { trade: "trade", book: "book" }, prefix: true

  before_validation { self.scope = self.class.scope_for(rule_type) }
  validates :rule_type, inclusion: { in: TRADE_TYPES + BOOK_TYPES }
  validate :required_params_present
  validate :book_params_positive, if: :scope_book?

  def self.scope_for(rule_type) = BOOK_TYPES.include?(rule_type.to_s) ? "book" : "trade"

  # The rule of each type that judges a setup, in one query: the setup's own row wins, the global row is the
  # fallback. The one place that sentence is written.
  def self.active_set_for(setup, scope: "trade")
    active.where(scope: scope, setup: [ nil, setup ]).group_by(&:rule_type).transform_values { |rules| rules.find { |r| r.setup_id == setup&.id } || rules.find { |r| r.setup_id.nil? } }
  end

  def self.active_for(rule_type, setup: nil) = active_set_for(setup, scope: scope_for(rule_type))[rule_type.to_s]
  def self.params_for(rule_type, setup: nil) = active_for(rule_type, setup: setup)&.params || {}
  # The floor under any allocation order, or nil when there is no rule (and then nothing is proposed).
  def self.min_rebalance_notional = active_for("min_rebalance_notional")&.then { |rule| BigDecimal(rule.param(:amount).to_s) }

  # The next version of this rule, superseding this one, in one transaction and one audit row.
  def supersede!(params:, user:, mode: nil, note: nil, override_reason: nil)
    supersede_with!({ rule_type: rule_type, setup: setup, params: params, mode: mode.presence || self.mode }, user: user, note: note, override_reason: override_reason) do |successor, override|
      AuditEvent.log("rule_changed", actor: :human, user: user, subject: successor, reason: successor.note,
                     data: { rule_type: rule_type, setup: setup&.name, before: { params: self.params, mode: self.mode }, after: { params: successor.params, mode: successor.mode },
                             version: successor.version, during_halt: override.present?, override_reason: override })
    end
  end

  def param(name) = params.fetch(name.to_s) { raise KeyError, "#{rule_type} rule has no #{name}" }
  def param_keys = (params.keys + Array(REQUIRED_PARAMS[rule_type])).uniq
  def mode_choosable? = rule_type == "wash_sale"
  # Book rules have no proposals to re-judge; the band is previewed against last night's drift rows instead.
  def previewable? = scope_trade? || rule_type == "rebalance_band"

  # What a candidate version would say, without writing: the waiting proposals for a trade rule, the stored drift for the band.
  def preview(params:, mode: nil)
    rule_type == "rebalance_band" ? Allocation::BandPreview.new(self, params: params) : RulePreview.new(self, params: params, mode: mode)
  end

  # Whether this is the row the evaluator would pick for the proposal: the setup's own row wins, the global row
  # is the fallback for setups without one.
  def applies_to?(proposal) = self.class.active_for(rule_type, setup: proposal.setup) == self # RulePreview resolves once per proposal; a handful at most

  private
    # A book rule's every parameter is a positive number, and a band a percent: an unreadable one would stop the nightly check.
    def book_params_positive
      params.to_h.slice(*REQUIRED_PARAMS[rule_type]).each do |key, value|
        number = BigDecimal(value.to_s, exception: false)
        errors.add(:params, "#{key} must be a positive number") unless number&.positive?
        errors.add(:params, "#{key} cannot exceed 100") if rule_type == "rebalance_band" && number && number > 100
      end
    end

    def required_params_present
      missing = REQUIRED_PARAMS.fetch(rule_type.to_s, []).reject { |key| params.to_h[key].present? }
      errors.add(:params, "is missing #{missing.to_sentence}") if missing.any?
    end
end
