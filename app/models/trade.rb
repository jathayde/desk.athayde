# One instrument's position lifecycle from zero back to zero. Every aggregate here is a pure function of
# the legs, recomputed after any leg changes; nothing is updated incrementally.
class Trade < ApplicationRecord
  DIVIDEND_AFTER_CLOSE_WINDOW = 90.days
  # Reasons in order of seriousness; a more serious reason replaces a lesser one, never the reverse.
  REVIEW_REASONS = %w[ corporate_action ordering_ambiguous position_missing bootstrapped missing_stop missing_setup ].freeze

  belongs_to :account
  belongs_to :instrument
  belongs_to :setup, optional: true
  belongs_to :order_proposal, optional: true
  has_many :trade_legs, dependent: :destroy

  enum :status, { open: "open", closed: "closed" }
  enum :review_reason, REVIEW_REASONS.index_by(&:itself), prefix: :review, validate: { allow_nil: true }

  normalizes :post_mortem, with: ->(text) { text.presence }

  scope :journaled, -> { joins(:account).merge(Account.trading) }
  scope :needing_review, -> { journaled.where(needs_review: true) }
  # Most serious reason first, never-skipped before skipped, oldest first.
  scope :review_queue, -> { needing_review.in_order_of(:review_reason, REVIEW_REASONS).order(Arel.sql("review_deferred_at ASC NULLS FIRST"), :created_at) }
  scope :in_setup, ->(name) { joins(:setup).where(setups: { name: name }) }
  scope :in_symbol, ->(symbol) { joins(:instrument).where(instruments: { symbol: symbol.to_s.upcase }) }
  scope :opened_after, ->(date) { where(opened_at: date.beginning_of_day..) }
  scope :closed_after, ->(date) { where(closed_at: date.beginning_of_day..) }
  scope :newest_first, -> { order(Arel.sql("COALESCE(trades.closed_at, trades.opened_at, trades.created_at) DESC"), id: :desc) }
  scope :missing_post_mortem, -> { closed.where(post_mortem: nil, needs_review: false, excluded_from_stats: false) }
  # bootstrapped means "has a plug leg now": a trade whose entry the journal never saw stays out of the stats.
  scope :eligible_for_stats, -> { closed.where(needs_review: false, excluded_from_stats: false, bootstrapped: false).where("initial_risk > 0") }

  validate :stop_below_entry, on: :review
  validates :setup, presence: { message: "is required: pick one or name a new one" }, on: :review

  # The next trade waiting after this one, in queue order.
  def self.next_to_review(after:) = review_queue.excluding(after).first

  # The journal browser's views of the journaled trades, by name.
  def self.listing(name)
    case name.to_s
    when "closed" then journaled.closed.order(closed_at: :desc, id: :desc)
    when "needs_review" then review_queue
    when "missing_post_mortem" then journaled.missing_post_mortem.order(closed_at: :desc, id: :desc)
    else journaled.open.order(opened_at: :desc, id: :desc)
    end
  end

  def realized_r_available? = initial_risk.present? && initial_risk.positive?
  def reviewed? = journal_completed_at.present? || excluded_from_stats?

  # A finished review is never undone by the journal; only a more serious reason can reopen it, and a lesser
  # reason never outranks the one already set.
  def flag!(reason)
    reason = reason.to_s
    raise ArgumentError, "unknown review reason #{reason}" unless REVIEW_REASONS.include?(reason)
    return if reviewed? && REVIEW_REASONS.index(reason) >= REVIEW_REASONS.index("bootstrapped")
    return if needs_review? && review_reason.present? && REVIEW_REASONS.index(review_reason) <= REVIEW_REASONS.index(reason)
    update!(needs_review: true, review_reason: reason)
  end

  def clear_flag!(reason)
    update!(needs_review: false, review_reason: nil) if needs_review? && review_reason == reason.to_s
  end

  # The synthetic entry leg that reconciles the journal to the broker. It sorts first and is scaled by every later
  # split, so plug = (broker quantity − quantity from linked legs) / cumulative ratio. Deleted at zero, and the
  # bootstrapped flag follows the plug: present while it exists, cleared when it goes.
  def reconcile_plug!(broker_quantity:, average_price:)
    linked = Ledger.new(ordered_legs.reject(&:plug?))
    plug_quantity = (broker_quantity - linked.running) / linked.ratio
    # Looked up, never built: an unsaved leg left on the association would be autosaved by recompute!.
    plug = trade_legs.find_by(activity_id: nil, kind: :entry)
    if plug_quantity.positive?
      changed = plug.nil? || plug.quantity != plug_quantity
      price = average_price && average_price * linked.ratio # the broker's post-split average, in the plug's pre-split units
      attributes = { quantity: plug_quantity, price: price, cash_amount: price ? -(plug_quantity * price) : nil, note: "plug" }
      plug ? plug.update!(attributes) : trade_legs.create!(attributes.merge(kind: :entry))
      update!(bootstrapped: true) unless bootstrapped?
      flag!(:bootstrapped) if changed
    else
      plug&.destroy!
      update!(bootstrapped: false) if bootstrapped?
      clear_flag!(:bootstrapped)
      flag!(:missing_setup) if setup.nil? && order_proposal.nil? && !reviewed?
    end
    recompute!
  end

  # Legs in execution order; the plug (no time) sorts first.
  def ordered_legs = trade_legs.includes(activity: :order).order(Arel.sql("executed_at ASC NULLS FIRST"), :id)

  # The planned stop is kept in original-entry units; splits since then scale it for display.
  def current_planned_stop = planned_stop && planned_stop / Ledger.new(ordered_legs).ratio

  def recompute!
    legs = ordered_legs.to_a
    ledger = Ledger.new(legs)
    closed = ledger.running.zero? && ledger.closing_leg.present?
    initial = ledger.initial_entry_legs
    initial_quantity = initial.sum(&:quantity) if initial.any?
    unpriced_plug = legs.any? { |l| l.plug? && l.price.nil? }

    assign_attributes(
      quantity: ledger.running,
      peak_quantity: ledger.peak,
      status: closed ? :closed : :open,
      opened_at: ledger.first_fill&.executed_at,
      closed_at: closed ? ledger.closing_leg.executed_at : nil,
      avg_entry: ledger.avg_entry,
      avg_exit: ledger.avg_exit,
      initial_quantity: initial_quantity,
      initial_risk: initial_risk_for(initial, plug: legs.any?(&:plug?)),
      total_risk: total_risk_for(legs),
      realized_pnl: closed && !unpriced_plug ? ledger.cash : nil,
      stopped_out: closed && ledger.closing_leg.activity&.order&.stop? == true
    )
    self.realized_r = closed && realized_r_available? ? realized_pnl / initial_risk : nil
    clear_flag!(:position_missing) if closed && ledger.closing_leg.activity_id
    save!
  end

  # The review form: the stop and setup are known now. A closed legacy holding takes setup and thesis only;
  # a stop typed in after the fact would give it an R it never had. Returns false with errors when the
  # rules are not met, so every caller (form or tool) gets the same answer.
  def review(setup:, planned_stop:, thesis:, user:)
    previous_setup = self.setup
    assign_attributes(setup: setup, thesis: thesis, needs_review: false, review_reason: nil, review_deferred_at: nil, journal_completed_at: Time.current)
    self.planned_stop = planned_stop unless closed? && bootstrapped?
    return false unless save(context: :review)
    recompute!
    AuditEvent.log("trade_reviewed", actor: :human, user: user, subject: self, data: { setup: setup&.name, planned_stop: self.planned_stop&.to_s })
    recompute_setup_stats(previous_setup, setup)
    true
  end

  def review!(**)
    review(**) or raise ActiveRecord::RecordInvalid, self
    self
  end

  # Skip: later, not never.
  def defer_review! = update!(review_deferred_at: Time.current)

  def exclude!(user:)
    update!(excluded_from_stats: true, needs_review: false, review_reason: nil)
    AuditEvent.log("trade_reviewed", actor: :human, user: user, subject: self, data: { excluded: true })
    recompute_setup_stats(setup)
    self
  end

  # One walk over the legs, accumulating everything recompute! needs.
  class Ledger
    attr_reader :running, :peak, :cash, :ratio, :closing_leg, :first_fill

    def initialize(legs)
      @legs = legs
      @running = @peak = @entry_qty = @entry_cost = @exit_qty = @exit_proceeds = @cash = BigDecimal("0")
      @ratio = BigDecimal("1")
      legs.each { |leg| apply(leg) }
    end

    def avg_entry = @entry_qty.positive? ? @entry_cost / @entry_qty : nil
    def avg_exit = @exit_qty.positive? ? @exit_proceeds / @exit_qty : nil

    # The initial entry: every fill from the first fill's order (a partial fill is one entry); without an order
    # id, every entry fill on the first fill's trade date.
    def initial_entry_legs
      return [] unless first_fill
      order_id = first_fill.activity.broker_order_id
      entries = @legs.select { |l| l.kind_entry? && l.activity }
      order_id ? entries.select { |l| l.activity.broker_order_id == order_id } : entries.select { |l| l.activity.trade_date == first_fill.activity.trade_date }
    end

    private
      def apply(leg)
        case leg.kind
        when "entry"
          @running += leg.quantity
          @entry_qty += leg.quantity
          @entry_cost += leg.quantity * (leg.price || 0)
          @first_fill ||= leg if leg.activity_id
        when "exit"
          @running -= leg.quantity
          @exit_qty += leg.quantity
          @exit_proceeds += leg.quantity * (leg.price || 0)
          @closing_leg = leg if @running.zero?
        when "adjustment"
          if leg.ratio
            @running *= leg.ratio
            @entry_qty *= leg.ratio
            @exit_qty *= leg.ratio
            @ratio *= leg.ratio
          elsif leg.quantity
            @running += leg.quantity
          end
        end
        @cash += leg.cash_amount || 0
        @peak = @running if @running > @peak
      end
  end

  private
    # Fixed to the initial entry at its weighted price, in original-entry units. Nil, never a number, when the
    # stop is unknown, the stop is above the entry, or a plug means the journal never saw the real entry.
    def initial_risk_for(initial_legs, plug:)
      return nil if plug || planned_stop.blank? || initial_legs.empty?
      quantity = initial_legs.sum(&:quantity)
      average = initial_legs.sum { |l| l.quantity * (l.price || 0) } / quantity
      risk = quantity * (average - planned_stop)
      risk.positive? ? risk : nil
    end

    def total_risk_for(legs)
      return nil if planned_stop.blank?
      legs.select { |l| l.kind_entry? && l.price && !l.plug? }.sum { |l| [ l.quantity * (l.price - planned_stop), 0 ].max }
    end

    def recompute_setup_stats(*setups)
      setups.compact.uniq.each { |s| Journal::RecomputeSetupStatsJob.perform_later(s) }
    end

    def stop_below_entry
      return if planned_stop.blank? || avg_entry.blank? || planned_stop < avg_entry
      errors.add(:planned_stop, "at or above the average entry gives no risk to measure; leave it blank or set it below #{avg_entry.round(2)}")
    end
end
