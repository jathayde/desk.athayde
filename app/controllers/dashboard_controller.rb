class DashboardController < ApplicationController
  def show
    @desk = Desk.new
  end
end
