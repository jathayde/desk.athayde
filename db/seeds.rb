# Access is by allowlist: only seeded users can request a sign-in link.
{ "john@athayde.com" => "John", "whitney@athayde.com" => "Whitney" }.each do |email_address, name|
  User.find_or_initialize_by(email_address:).update!(name:)
end
