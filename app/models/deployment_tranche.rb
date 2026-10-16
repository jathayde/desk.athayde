# One week's share of a staged deposit (docs/phase-2.5-plan.md §0.8). The drift check proposes it on or after its
# due date; a tranche that buys not one whole share of any target rolls into the next, and the last one with
# nothing to roll into leaves its cash as cash (and says so). The night-by-night rules are Deploying's.
class DeploymentTranche < ApplicationRecord
  include Deploying

  belongs_to :cash_inflow
  has_many :order_proposals, as: :allocation_source, dependent: :restrict_with_exception

  enum :status, %w[ scheduled proposed rolled done ].index_by(&:itself), validate: true

  scope :due, ->(date) { scheduled.where(due_on: ..date).order(:due_on, :week) }

  def label = "week #{week} of #{cash_inflow.label}"

  def deploy!(planner) = super.tap { cash_inflow.change_status!(:done) if cash_inflow.tranches.scheduled.none? && !cash_inflow.status_done? }
  def placed!(results) = change_status!(:proposed, outcomes: results)

  def change_status!(status, **detail)
    before = self.status
    update!(status: status, detail: self.detail.merge(detail.stringify_keys).compact)
    AuditEvent.log("deployment_tranche_status_changed", actor: :system, subject: self, data: { before: before, after: self.status, amount: amount.to_s, **detail })
    self
  end

  # Whatever bought nothing goes into the next scheduled tranche, audited on both, or stays cash after the last.
  def give_up!(results, **detail)
    following = cash_inflow.tranches.scheduled.where.not(id: id).lock.first
    return change_status!(:done, left_as_cash: amount.to_s, outcomes: results, **detail).tap { Alert.cash_left(cash_inflow, amount) } unless following
    before = following.amount
    following.update!(amount: before + amount)
    AuditEvent.log("deployment_tranche_status_changed", actor: :system, subject: following, data: { before: following.status, after: following.status, amount_before: before.to_s, amount: following.amount.to_s, rolled_from_week: week })
    change_status!(:rolled, into_week: following.week, outcomes: results, **detail)
  end
end
