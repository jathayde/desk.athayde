# The weekly fund-flow datapoint (PRD §5.12.6): ICI's net long-term fund flow, in billions, entered by hand on the
# system page until a source is verified (docs/phase-2.5-plan.md §8). Context in the Sunday review, never an input.
class FundFlow < ApplicationRecord
  DEFAULT_SOURCE = "ICI weekly release, by hand"

  normalizes :as_of, with: -> { it.beginning_of_week } # one row a week, whichever day of it was typed
  validates :as_of, presence: true, uniqueness: true
  validates :amount, numericality: { greater_than: -1_000_000, less_than: 1_000_000 } # billions: anything past this is a typo
  validate :not_in_the_future
  validates :source, presence: true

  def self.record!(as_of:, amount:, source:, user:)
    transaction do
      flow = find_or_initialize_by(as_of: as_of)
      before = flow.persisted? ? { amount: flow.amount.to_s, source: flow.source } : nil
      flow.assign_attributes(amount: amount, source: source.presence || DEFAULT_SOURCE)
      return flow if flow.persisted? && !flow.changed? # the same numbers again: nothing changed, nothing to audit
      flow.update!(fetched_at: Time.current)
      AuditEvent.log("fund_flow_changed", actor: :human, user: user, subject: flow, data: { as_of: flow.as_of.iso8601, before: before, after: { amount: flow.amount.to_s, source: flow.source } })
      flow
    end
  end

  def self.latest = order(as_of: :desc).first
  def week_label = as_of.strftime("%b %-d")
  def summary = "$#{ActiveSupport::NumberHelper.number_to_rounded(amount, precision: 1)}B, week of #{week_label} (#{source})"

  private
    def not_in_the_future = (errors.add(:as_of, "is in the future") if as_of && as_of > MarketDay.today)
end
