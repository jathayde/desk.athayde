class InstrumentsController < ApplicationController
  # Only a held instrument can be marked, and only in the two states the button offers.
  def update
    position = Position.joins(:account).merge(Account.trading).find_by!(instrument_id: params[:id])
    instrument = position.instrument
    case params[:delisted]
    when "1" then instrument.delist!(user: Current.user, price: position.last_price)
    when "0" then instrument.relist!(user: Current.user)
    else return head(:bad_request)
    end
    redirect_to system_path, notice: "#{instrument.symbol} marked #{instrument.delisted? ? 'delisted' : 'listed'}."
  end
end
