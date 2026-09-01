# The suite never touches the live Schwab API. Cassettes are scrubbed of credentials, tokens,
# account hashes, and plaintext account numbers before they are written. Requests match on
# method and URI only, because scrubbed bodies would never match a live refresh grant.
VCR.configure do |c|
  c.cassette_library_dir = Rails.root.join("spec/cassettes")
  c.hook_into :webmock
  c.configure_rspec_metadata!
  c.default_cassette_options = { record: :none, match_requests_on: %i[ method uri ] }
  c.allow_http_connections_when_no_cassette = false

  c.filter_sensitive_data("<SCHWAB_APP_KEY>") { Rails.application.credentials.dig(:schwab, :app_key) }
  c.filter_sensitive_data("<SCHWAB_APP_SECRET>") { Rails.application.credentials.dig(:schwab, :app_secret) }

  c.before_record do |interaction|
    interaction.request.headers.delete("Authorization")
    interaction.request.body = VcrScrub.form(interaction.request.body)
    interaction.request.uri = VcrScrub.uri(interaction.request.uri)
    interaction.response.body = VcrScrub.json(interaction.response.body)
  end
end

module VcrScrub
  SECRET_FORM_FIELDS = %w[ client_id client_secret code refresh_token access_token ].freeze
  SECRET_JSON_FIELDS = %w[ access_token refresh_token id_token ].freeze
  ACCOUNT_HASH = /[0-9A-F]{64}/i

  def self.form(body)
    return body if body.blank?
    body.gsub(/(#{SECRET_FORM_FIELDS.join("|")})=[^&]*/) { "#{$1}=<REDACTED>" }
  end

  def self.uri(uri)
    uri.gsub(%r{/accounts/#{ACCOUNT_HASH}}, "/accounts/<ACCOUNT_HASH>")
  end

  def self.json(body)
    return body if body.blank?
    body
      .gsub(/"(#{SECRET_JSON_FIELDS.join("|")})"\s*:\s*"[^"]*"/) { %("#{$1}": "<REDACTED>") }
      .gsub(/"hashValue"\s*:\s*"[^"]*"/, '"hashValue": "<ACCOUNT_HASH>"')
      .gsub(/"accountNumber"\s*:\s*"?\d+"?/, '"accountNumber": "<ACCOUNT_NUMBER>"')
      .gsub(ACCOUNT_HASH, "<ACCOUNT_HASH>")
  end
end
