# An instrument's authored asset class and tags, from the targets screen.
class Instruments::ClassificationsController < ApplicationController
  before_action :require_approver

  def update
    instrument = Instrument.find(params[:instrument_id]).classify!(asset_class: params[:asset_class], tags: params[:tags], user: Current.user)
    redirect_to allocation_targets_path(anchor: "instruments"), notice: "#{instrument.symbol} saved."
  rescue ActiveRecord::RecordNotUnique
    redirect_to allocation_targets_path(anchor: "instruments"), alert: "Another edit saved that instrument at the same moment; check it and save again."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to allocation_targets_path(anchor: "instruments"), alert: e.record.errors.full_messages.to_sentence
  end
end
