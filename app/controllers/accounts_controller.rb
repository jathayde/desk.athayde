class AccountsController < ApplicationController
  def update
    account = Account.find(params[:id])
    account.configure!(account_type: params[:account_type].presence, trading_enabled: params[:trading_enabled] == "1", nickname: params[:nickname], user: Current.user)
    redirect_to system_path, notice: "#{account.label} updated."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to system_path, alert: e.record.errors.full_messages.to_sentence
  end
end
