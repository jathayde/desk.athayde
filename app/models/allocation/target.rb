# A weight the book should hold, for one instrument or one authored asset class (docs/phase-2.5-plan.md §0.2).
# Data, not policy: edited in place with an audit row carrying before and after. The active set never sums past
# one, checked under a transaction-scoped lock so two edits cannot both pass.
class Allocation::Target < ApplicationRecord
  belongs_to :instrument, optional: true
  has_many :drifts, class_name: "Allocation::Drift", foreign_key: :allocation_target_id, inverse_of: :target, dependent: :restrict_with_exception

  scope :active, -> { where(active: true) }

  normalizes :asset_class, with: ->(name) { name.squish.downcase.presence }
  validates :target_weight, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validate :instrument_or_class
  validate :active_set_within_whole, if: :active?

  # A target for a symbol the desk already knows, or for a class; nothing here asks Schwab.
  def self.add!(user:, target_percent:, symbol: nil, asset_class: nil)
    instrument = Instrument.where(delisted_at: nil).find_by(symbol: symbol.to_s.strip.upcase) if symbol.present? # a reused symbol means the listed row
    target = new(instrument: instrument, asset_class: (asset_class unless symbol.present?), target_percent: target_percent)
    target.errors.add(:base, "#{symbol.to_s.strip.upcase} is not known to the desk yet; it arrives with a position, an order, or a proposal") if symbol.present? && instrument.nil?
    raise ActiveRecord::RecordInvalid, target if target.errors.any?
    transaction do
      lock_set!
      target.save!
      target.audit!(user, before: nil)
    end
    target
  end

  def self.lock_set! = connection.execute("SELECT pg_advisory_xact_lock(hashtext('allocation_targets'))")

  def reweigh!(target_percent, user:) = change!(user) { update!(target_percent: target_percent) }
  def retire!(user:) = change!(user) { update!(active: false) }
  # The operator wants the planner to ask again although the last rebalance here was rejected.
  def clear_rejection!(user:) = change!(user) { update!(rejection_cleared_at: Time.current) }

  # Typed as a percent; unreadable input is zero, which the weight validation refuses.
  def target_percent=(percent)
    self.target_weight = ((BigDecimal(percent.to_s.strip, exception: false) || 0) / 100).round(6) # validated as it will be stored
  end

  # The operator rejected the last rebalance here on this side, and every measured check since has still seen
  # this side outside the band, so asking again each night at a new price would be noise. Lifted by the drift
  # going back inside the band or changing side, or by the operator clearing it; an unmeasured night lifts nothing.
  def rejection_standing?(side, before:)
    rejected = OrderProposal.rejected.kind_rebalance.where(allocation_source: drifts).order(:decided_at).last
    return false if rejected.nil? || rejected.side != side
    return false if rejection_cleared_at && rejection_cleared_at > rejected.decided_at
    drifts.where(as_of: rejected.allocation_source.as_of...before).where.not(drift: nil).none? { |drift| drift.action_none? || drift.side != side }
  end

  # Whether the targets screen offers "Ask again": a rejection stands on either side as of today's check.
  def rejection_standing_now? = %w[ buy sell ].any? { |side| rejection_standing?(side, before: MarketDay.today + 1) }

  def label = instrument ? instrument.symbol : asset_class
  def class_target? = asset_class.present?

  # The audit row every write leaves, inside the write's transaction.
  def audit!(user, before:)
    AuditEvent.log("allocation_target_changed", actor: :human, user: user, subject: self, data: { target: label, before: before, after: audit_state })
  end

  private
    # Under the set's lock, so the 100 percent check sees every other edit, and re-read under it, so the audit
    # row's before is current and a target retired in the meantime is refused rather than written to.
    def change!(user)
      transaction do
        self.class.lock_set!
        reload
        raise ActiveRecord::StaleObjectError.new(self, "change") unless active?
        before = audit_state
        yield
        audit!(user, before: before)
      end
      self
    end

    def audit_state = { target_weight: target_weight.to_s, active: active, rejection_cleared_at: rejection_cleared_at&.iso8601 }.compact

    def instrument_or_class
      errors.add(:base, "Name an instrument or an asset class, not both") if instrument_id.present? == asset_class.present?
    end

    def active_set_within_whole
      others = self.class.active.where.not(id: id).sum(:target_weight)
      errors.add(:target_weight, "would bring the active targets to #{((others + target_weight.to_d) * 100).round(2).to_s("F")}%, past 100%") if others + target_weight.to_d > 1
    end
end
