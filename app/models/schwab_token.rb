class SchwabToken < ApplicationRecord
  encrypts :access_token, :refresh_token
end
