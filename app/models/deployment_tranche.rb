# One week's share of a staged deposit (docs/phase-2.5-plan.md §0.8). The drift check proposes it on or after its
# due date; a tranche that buys not one whole share of any target rolls into the next, and the last one with
# nothing to roll into leaves its cash as cash. A night that defers (unsettled cash, a halt, a waiting proposal, no
# price) leaves it scheduled for the next, up to the deposit's DEFERRED_NIGHTS, and then it rolls.
class DeploymentTranche < ApplicationRecord
  belongs_to :cash_inflow
  has_many :order_proposals, as: :allocation_source, dependent: :restrict_with_exception

  enum :status, %w[ scheduled proposed rolled done ].index_by(&:itself), validate: true

  scope :due, ->(date) { scheduled.where(due_on: ..date).order(:due_on, :week) }

  def label = "week #{week} of #{cash_inflow.label}"

  def deploy!(planner)
    outcomes = planner.deploy(self, amount)
    results = outcomes&.to_h { [ it.target, it.result ] }
    if outcomes&.any?(&:proposed?)
      change_status!(:proposed, outcomes: results)
    elsif outcomes&.none?(&:deferred?) || detail["deferred_nights"].to_i + 1 >= CashInflow::DEFERRED_NIGHTS
      roll!(results)
    else
      change_status!(:scheduled, deferred_nights: detail["deferred_nights"].to_i + 1, outcomes: results || { "tonight" => "no calendar or no target to place it" })
    end
    cash_inflow.change_status!(:done) if cash_inflow.tranches.scheduled.none?
    self
  end

  def change_status!(status, **detail)
    before = self.status
    update!(status: status, detail: self.detail.merge(detail.stringify_keys).compact)
    AuditEvent.log("deployment_tranche_status_changed", actor: :system, subject: self, data: { before: before, after: self.status, amount: amount.to_s, **detail })
    self
  end

  private
    # Whatever bought nothing goes into the next scheduled tranche, or stays cash after the last.
    def roll!(results)
      following = cash_inflow.tranches.scheduled.where.not(id: id).lock.first
      following&.update!(amount: following.amount + amount)
      following ? change_status!(:rolled, into_week: following.week, outcomes: results) : change_status!(:done, left_as_cash: amount.to_s, outcomes: results)
    end
end
