class Instrument < ApplicationRecord
  belongs_to :predecessor_instrument, class_name: "Instrument", optional: true
  has_many :positions, dependent: :restrict_with_exception
  has_many :orders, dependent: :restrict_with_exception
  has_many :activities, dependent: :restrict_with_exception
  has_many :trades, dependent: :restrict_with_exception
  has_many :tags, class_name: "InstrumentTag", dependent: :destroy

  scope :delisted, -> { where.not(delisted_at: nil) }

  normalizes :cusip, with: ->(c) { c.strip.upcase.presence }
  normalizes :symbol, with: ->(s) { s.strip.upcase }
  normalizes :asset_class, with: ->(name) { name.squish.downcase.presence }

  validates :symbol, presence: true
  validate :predecessor_is_another_instrument

  # A holding the market no longer prices: still synced and journaled, excluded from protection counts and
  # risk sums, named on the dashboard as one line. Cleared by the operator, or by Schwab printing a price that
  # differs from the one it carried at delisting (the same stale mark repeated is not a market).
  def delisted? = delisted_at.present?
  def priced_again?(price) = delisted? && price.present? && price.positive? && price != delisted_price

  def delist!(user:, price: nil)
    return self if delisted?
    update!(delisted_at: Time.current, delisted_price: price)
    AuditEvent.log("instrument_delisted", actor: :human, user: user, subject: self, data: { symbol: symbol, price: price&.to_s })
    self
  end

  # No user means the positions sync did it, with the price that changed as the reason.
  def relist!(user: nil, reason: nil)
    return self unless delisted?
    update!(delisted_at: nil, delisted_price: nil)
    AuditEvent.log("instrument_relisted", actor: user ? :human : :system, user: user, subject: self, reason: reason, data: { symbol: symbol })
    self
  end

  DISCRETIONARY_TAGS = %w[ leveraged amplified ].freeze # never rebalanced mechanically (docs/phase-2.5-plan.md §0.7)

  def tag_names = tags.map(&:tag).sort
  def tagged?(tag) = tag_names.include?(tag.to_s)
  def discretionary? = (tag_names & DISCRETIONARY_TAGS).any?

  # The authored asset class and tags (docs/phase-2.5-plan.md §0.3), each change its own audit row; an unchanged
  # field writes nothing.
  def classify!(asset_class:, tags:, user:)
    asset_class = self.class.normalize_value_for(:asset_class, asset_class.to_s)
    wanted = Array(tags).map(&:to_s).compact_blank.uniq.sort
    transaction do
      if asset_class != self.asset_class
        AuditEvent.log("instrument_classified", actor: :human, user: user, subject: self, data: { symbol: symbol, before: self.asset_class, after: asset_class })
        update!(asset_class: asset_class)
      end
      (wanted - tag_names).each do |tag|
        self.tags.create!(tag: tag)
        AuditEvent.log("instrument_tagged", actor: :human, user: user, subject: self, data: { symbol: symbol, tag: tag, tagged: true })
      end
      self.tags.where(tag: tag_names - wanted).find_each do |removed|
        removed.destroy!
        AuditEvent.log("instrument_tagged", actor: :human, user: user, subject: self, data: { symbol: symbol, tag: removed.tag, tagged: false })
      end
    end
    self.tags.reset
    self
  end

  # Identity in order of trust: CUSIP, Schwab instrument id, then symbol and asset type among rows that have
  # no CUSIP, then a Schwab lookup by symbol, then a provisional row. A weaker match backfills a missing
  # identifier from the ref but never overwrites a differing one.
  def self.resolve(ref, attempt: 1)
    return nil if ref.nil? || (ref.symbol.blank? && ref.cusip.blank?)
    found = find_by(cusip: ref.cusip) if ref.cusip.present?
    ref = ref.with(symbol: lookup_symbol(ref.cusip)) if found.nil? && ref.symbol.blank?
    return nil if ref.symbol.blank? # a CUSIP Schwab cannot name is quarantined by the caller, not invented here
    found ||= find_by(schwab_instrument_id: ref.instrument_id) if ref.instrument_id.present?
    found ||= where(cusip: nil, symbol: ref.symbol, asset_type: ref.asset_type).first
    found ? found.absorb(ref) : create_from(ref)
  rescue ActiveRecord::RecordNotUnique
    # Another feed created or backfilled it between our lookup and our write; look once more, then give up.
    raise Schwab::MappingError, "instrument #{ref.symbol} keeps colliding on identity" if attempt > 1
    resolve(ref, attempt: attempt + 1)
  end

  def self.create_from(ref)
    cusip = ref.cusip.presence || lookup_cusip(ref.symbol)
    if cusip && (existing = find_by(cusip: cusip))
      return existing.absorb(ref.with(cusip: cusip))
    end
    create!(cusip: cusip, schwab_instrument_id: ref.instrument_id, symbol: ref.symbol, asset_type: ref.asset_type, description: ref.description).tap do |instrument|
      AuditEvent.log("instrument_identity_fallback", actor: :system, subject: instrument, data: { symbol: ref.symbol, asset_type: ref.asset_type }) if cusip.blank?
    end
  end

  def self.lookup_symbol(cusip)
    Schwab::InstrumentRef.from(Schwab.client(wait: false).instrument_by_cusip(cusip).first)&.symbol
  rescue Schwab::Error
    nil
  end

  def self.lookup_cusip(symbol)
    Schwab::InstrumentRef.from(Schwab.client(wait: false).instrument_by_symbol(symbol).first)&.cusip
  rescue Schwab::Error
    nil
  end

  # A weaker-key match learns identifiers it lacked; a conflicting identifier already owned elsewhere is left alone.
  def absorb(ref)
    update!(cusip: ref.cusip) if cusip.blank? && ref.cusip.present? && !self.class.exists?(cusip: ref.cusip)
    update!(schwab_instrument_id: ref.instrument_id) if schwab_instrument_id.blank? && ref.instrument_id.present? && !self.class.exists?(schwab_instrument_id: ref.instrument_id)
    rename!(ref.symbol) if cusip.present? && cusip == ref.cusip && symbol != ref.symbol
    self
  end

  def rename!(new_symbol, at: Time.current)
    return if new_symbol == symbol
    update!(symbol: new_symbol, symbol_history: symbol_history + [ { "symbol" => symbol, "until" => at.utc.iso8601 } ])
  end

  private
    def predecessor_is_another_instrument
      errors.add(:predecessor_instrument, "cannot be itself") if persisted? && predecessor_instrument_id == id
    end
end
