class Setup < ApplicationRecord
  has_many :trades, dependent: :restrict_with_exception
  has_many :risk_rules, dependent: :restrict_with_exception

  validates :name, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }

  # What the agent reads about the setups, from the tool and from the scheduled prompt alike.
  def self.agent_stats
    { setups: order(:name).map { |s| { name: s.name, active: s.active?, definition: s.definition, sample_size: s.sample_size, win_rate: s.win_rate,
                                       avg_r: s.avg_r, expectancy: s.expectancy, stats_computed_at: s.stats_computed_at } },
      eligibility: "closed, reviewed, not excluded, not bootstrapped, initial_risk > 0" }
  end

  def self.named(name)
    name = name.to_s.strip
    return nil if name.blank?
    where("lower(name) = ?", name.downcase).first || create!(name: name)
  end

  # The PRD's expectancy, win rate × average win − loss rate × average loss, is the mean R per trade by
  # identity, so it is avg_r under the name the PRD and the prompt use.
  def expectancy = avg_r

  # Rolling stats over closed, reviewed, included trades with a positive initial risk. A win is R above zero.
  # Realized R is net of what was paid; gross R adds back the measured, comparable costs, over the trades that
  # have them, beside the realized average over those same trades, so the difference is the cost and nothing else
  # (docs/phase-2.6-plan.md §0.8).
  def recompute_stats!
    eligible = trades.eligible_for_stats
    realized = eligible.pluck(:realized_r).compact
    gross, costed = eligible.where.not(gross_r: nil).pluck(:gross_r, :realized_r).transpose.presence || [ [], [] ]
    average = realized.sum / realized.size if realized.any?
    update!(sample_size: realized.size, avg_r: average,
            win_rate: average && realized.count(&:positive?).to_d / realized.size,
            gross_avg_r: gross.any? ? gross.sum / gross.size : nil, costed_avg_r: costed.any? ? costed.sum / costed.size : nil, cost_sample_size: gross.size,
            stats_computed_at: Time.current)
  end
end
