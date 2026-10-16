# New cash from the activities feed (PRD §5.12.3, docs/phase-2.5-plan.md §0.8), handled by the deployment policy in
# force when it was detected: at once (the next drift check deploys it), staged (weekly tranches), or asked (a
# thesis review about the deposit). Only deposits from the day the desk first had a policy count, so a backfilled
# history never deploys, and one under the minimum notional is recorded and left as cash.
class CashInflow < ApplicationRecord
  include Deploying

  STATUSES = %w[ pending proposed staged asked held done ].freeze
  DEFAULT_WEEKS = 4 # staging an asked deposit under a policy that names no weeks

  belongs_to :account
  belongs_to :activity
  belongs_to :deployment_policy
  has_many :tranches, -> { order(:due_on, :week) }, class_name: "DeploymentTranche", dependent: :restrict_with_exception
  has_one :thesis_review, -> { order(:id) }, dependent: :restrict_with_exception
  has_many :order_proposals, as: :allocation_source, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), prefix: true, validate: true

  # Committed to deployment: the nightly check pauses its buys while any of these stands.
  scope :committing, -> { where(status: %w[ pending asked ]).or(where(id: DeploymentTranche.scheduled.select(:cash_inflow_id))) }

  def self.detect!(account)
    policy = DeploymentPolicy.current or return []
    since = DeploymentPolicy.minimum(:created_at).in_time_zone(MarketDay::ZONE).to_date
    account.activities.deposit.where(status: [ nil, Schwab::Activity::VALID ], trade_date: since..).where.not(id: select(:activity_id)).order(:trade_date, :id).filter_map do |activity|
      next unless activity.net_amount&.positive? # a sign-disagreeing or returned deposit is not new cash
      transaction(requires_new: true) { create_from!(account, activity, policy) }
    rescue ActiveRecord::RecordNotUnique
      nil # another sync's job detected it first
    rescue StandardError => e # one bad row never holds up the deposits behind it
      Rails.error.report(e, handled: true, context: { job: "CashInflow.detect!", activity: activity.id })
      nil
    end
  end

  def self.create_from!(account, activity, policy)
    inflow = create!(account: account, activity: activity, amount: activity.flow_amount, detected_at: Time.current, deployment_policy: policy, status: :pending)
    AuditEvent.log("cash_inflow_detected", actor: :system, subject: inflow, data: { amount: inflow.amount.to_s, policy: policy.mode, policy_version: policy.version })
    inflow.apply_policy!
    inflow
  end

  ANSWERS = { "deploy" => "deploying at the next check", "stage" => "staged in weekly tranches", "hold" => "held as cash" }.freeze

  def apply_policy!
    minimum = RiskRule.min_rebalance_notional
    return change_status!(:done, below_minimum: minimum.to_s("F")) if minimum && amount < minimum
    case deployment_policy.mode
    when "immediate" then self # pending: tonight's check deploys it
    when "staged" then stage!(deployment_policy.weeks)
    when "ask" then ask!
    end
  end

  # N weekly tranches of an equal share, the last taking the rounding, the first due the day staging begins (the
  # deposit's day, or the day the operator answered) and each next one a week later; a due date that falls on a
  # closed day is proposed by the next trading day's check.
  def stage!(weeks, user: nil, from: detected_at.in_time_zone(MarketDay::ZONE).to_date)
    weeks = Integer(weeks, exception: false)
    raise ArgumentError, "stage over 1 to 52 weeks" unless weeks&.between?(1, 52)
    share = (amount / weeks).round(2, BigDecimal::ROUND_DOWN)
    transaction do
      weeks.times do |i|
        tranche = tranches.create!(week: i + 1, due_on: from + (i * 7), amount: i == weeks - 1 ? amount - share * (weeks - 1) : share)
        AuditEvent.log("deployment_tranche_scheduled", actor: user ? :human : :system, user: user, subject: tranche, data: { due_on: tranche.due_on.iso8601, amount: tranche.amount.to_s })
      end
      change_status!(:staged, user: user, weeks: weeks)
    end
  end

  def ask!
    transaction do
      ThesisReview.ask_about!(self)
      change_status!(:asked)
    end
  end

  # The operator's answer to an ask: deploy at the next check, stage from today, or hold as cash.
  def answer!(decision, user:, weeks: nil, reason: nil)
    lock!
    raise ActiveRecord::StaleObjectError.new(self, "answer") unless status_asked?
    case decision
    when "deploy" then change_status!(:pending, user: user, decided: "deploy")
    when "stage" then stage!(weeks.presence || default_weeks, user: user, from: MarketDay.today)
    when "hold" then change_status!(:held, user: user, reason: reason)
    end
  end

  # Deployed at once: proposed once any target takes a share (the shares that could not wait stay cash; proposing
  # them again would double the rest); a deposit reversed since it was detected is done and never deployed.
  def deploy!(planner) = still_deposited? ? super : change_status!(:done, reversed: true)
  def placed!(results) = change_status!(:proposed, proposed: results.values.count("proposed"), outcomes: results)

  def give_up!(results, **detail)
    change_status!(:done, outcomes: results, **detail).tap { Alert.cash_left(self, amount) unless results.value?("proposed") }
  end

  # Still a valid deposit of the amount detected: a later sync can return, cancel, or re-sign it.
  def still_deposited?
    activity.reload
    activity.deposit? && activity.status.in?([ nil, Schwab::Activity::VALID ]) && activity.net_amount&.positive? && activity.flow_amount == amount
  end

  def default_weeks = deployment_policy.weeks || DEFAULT_WEEKS

  def progress
    return "waiting on your answer" if status_asked?
    return "waiting since #{detail["deferred_nights"]} #{"night".pluralize(detail["deferred_nights"])} (#{detail["outcomes"].values.uniq.to_sentence})" if status_pending? && detail["deferred_nights"]
    return "at the next check" if status_pending?
    "#{tranches.count(&:scheduled?)} weekly tranches to go"
  end

  def change_status!(status, user: nil, **detail)
    before = self.status
    update!(status: status, detail: self.detail.merge(detail.stringify_keys).compact)
    AuditEvent.log("cash_inflow_status_changed", actor: user ? :human : :system, user: user, subject: self, data: { before: before, after: self.status, **detail })
    self
  end

  def label = "#{ActiveSupport::NumberHelper.number_to_currency(amount)} deposited #{activity.trade_date.strftime('%b %-d')}"
end
