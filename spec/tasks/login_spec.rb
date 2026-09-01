require "rails_helper"
require "rake"

RSpec.describe "login:link", type: :request do
  before { Rails.application.load_tasks unless Rake::Task.task_defined?("login:link") }

  it "prints a usable magic link for the given email" do
    user = create(:user, email_address: "john@athayde.com")
    expect { Rake::Task["login:link"].execute(email: "john@athayde.com") }
      .to output(%r{http://example.com/magic_link\?token=}).to_stdout
  end
end
