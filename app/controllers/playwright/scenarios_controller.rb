# Test environment only, and only on the fake adapter: resets the database to a named scenario and signs
# in a seeded user, because Playwright has no inbox to read a magic link from. Never routed elsewhere.
class Playwright::ScenariosController < ApplicationController
  allow_unauthenticated_access
  skip_forgery_protection
  before_action { head :not_found unless Rails.env.test? && Schwab.fake? }

  def show
    Playwright::Scenario.load!(params[:name])
    start_new_session_for(User.find_by!(email_address: "john@athayde.com"))
    redirect_to params[:then].presence_in(%w[ /trades /system ]) || root_path
  end
end
