# Every secret the app needs lives in credentials (docs/phase-1-plan.md §0.1). A production boot with one
# missing fails here, at start, rather than at the Sunday re-auth or the first brief. The image build runs
# with SECRET_KEY_BASE_DUMMY and no key, so it is exempt.
if Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
  credentials = Rails.application.credentials
  missing = {
    "secret_key_base" => credentials.secret_key_base,
    "active_record_encryption.primary_key" => credentials.dig(:active_record_encryption, :primary_key),
    "active_record_encryption.deterministic_key" => credentials.dig(:active_record_encryption, :deterministic_key),
    "active_record_encryption.key_derivation_salt" => credentials.dig(:active_record_encryption, :key_derivation_salt),
    "schwab.app_key" => credentials.dig(:schwab, :app_key),
    "schwab.app_secret" => credentials.dig(:schwab, :app_secret),
    "mcp.bearer_token" => credentials.dig(:mcp, :bearer_token),
    "anthropic.api_key" => credentials.dig(:anthropic, :api_key),
    "resend.api_key" => credentials.dig(:resend, :api_key)
  }.select { |_, value| value.blank? }.keys
  raise "production credentials are missing: #{missing.join(', ')} (edit with bin/rails credentials:edit --environment production)" if missing.any?
end
