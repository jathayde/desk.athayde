class User < ApplicationRecord
  MAGIC_LINK_TTL = 15.minutes

  has_many :sessions, dependent: :destroy
  has_many :devices, dependent: :destroy

  scope :notified, -> { where(notify: true) } # who hears from the desk: alerts, briefs, pushes; never the sign-in link

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  validates :email_address, :name, presence: true

  # Single use: the token embeds the nonce, and consuming a link rotates the nonce under a row lock.
  generates_token_for :magic_link, expires_in: MAGIC_LINK_TTL do
    magic_link_nonce
  end

  def magic_link_token = generate_token_for(:magic_link)

  # Returns the user and invalidates the link, or nil. Safe against two clicks racing each other.
  def self.consume_magic_link(token)
    user = find_by_token_for(:magic_link, token) or return
    user.with_lock do
      return unless user.reload == find_by_token_for(:magic_link, token)
      user.update!(magic_link_nonce: SecureRandom.hex(16), last_login_at: Time.current)
    end
    user
  end

  def send_magic_link
    MagicLinkMailer.sign_in(self).deliver_later
  end
end
