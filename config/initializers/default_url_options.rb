# URLs built outside a request (rake tasks, jobs) use the same host as mail.
Rails.application.default_url_options = Rails.application.config.action_mailer.default_url_options
