class DashboardController < ApplicationController
  def show
    @dashboard = Dashboard.new
  end
end
