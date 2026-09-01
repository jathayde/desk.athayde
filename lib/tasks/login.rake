namespace :login do
  desc "Print a one-time sign-in link for EMAIL (fallback when email delivery is down)"
  task :link, [ :email ] => :environment do |_, args|
    user = User.find_by!(email_address: args[:email])
    puts Rails.application.routes.url_helpers.magic_link_url(token: user.magic_link_token)
  end
end
