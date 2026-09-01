class SchwabToken < ApplicationRecord
  encrypts :access_token, :refresh_token

  def self.current = order(issued_at: :desc).first
end
