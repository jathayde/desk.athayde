class Setup < ApplicationRecord
  has_many :trades, dependent: :restrict_with_exception
  has_many :risk_rules, dependent: :restrict_with_exception

  validates :name, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }

  def self.named(name)
    name = name.to_s.strip
    return nil if name.blank?
    where("lower(name) = ?", name.downcase).first || create!(name: name)
  end

  # Rolling stats over closed, reviewed, included trades with a positive initial risk. A win is R above zero.
  def recompute_stats!
    realized = trades.eligible_for_stats.pluck(:realized_r).compact
    average = realized.sum / realized.size if realized.any?
    update!(sample_size: realized.size, avg_r: average, expectancy: average,
            win_rate: average && realized.count(&:positive?).to_d / realized.size,
            stats_computed_at: Time.current)
  end
end
