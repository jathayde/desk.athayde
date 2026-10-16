# The targets screen (docs/phase-2.5-plan.md §3): add, reweigh, and retire targets, and author each instrument's
# class and tags. Weights are typed as percents and stored as fractions.
class AllocationTargetsController < ApplicationController
  before_action :require_approver, except: :index

  def index
    @targets = Allocation::Target.active.includes(:instrument).order(:asset_class, :id)
    @drifts = Allocation::Drift.current.index_by(&:allocation_target_id)
    @band_rule = RiskRule.active_for("rebalance_band")
    @instruments = classifiable_instruments
  end

  def create
    target = Allocation::Target.add!(symbol: params[:symbol], asset_class: params[:asset_class], target_percent: params[:target_percent], user: Current.user)
    redirect_to allocation_targets_path, notice: "#{target.label} targets #{helpers.percent(target.target_weight, precision: 2)}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to allocation_targets_path, alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    redirect_to allocation_targets_path, alert: "That already has an active target; reweigh it instead."
  end

  def update
    target = Allocation::Target.find(params[:id]).reweigh!(params[:target_percent], user: Current.user)
    redirect_to allocation_targets_path, notice: "#{target.label} targets #{helpers.percent(target.target_weight, precision: 2)}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to allocation_targets_path, alert: e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::StaleObjectError
    redirect_to allocation_targets_path, alert: "That target was retired in the meantime."
  end

  private
    # Held, targeted, or watched: the instruments a class or tag could matter to.
    def classifiable_instruments
      held = Position.joins(:account).merge(Account.trading).select(:instrument_id)
      Instrument.includes(:tags).where(id: held).or(Instrument.where(id: Allocation::Target.active.select(:instrument_id)))
                .or(Instrument.where(id: WatchlistItem.watching.select(:instrument_id))).order(:symbol)
    end
end
