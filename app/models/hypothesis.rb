# A setup's edge, written down before the evidence (docs/phase-2.6-plan.md §0.5, §0.6). The claim is frozen by
# the database; a changed parameter is a variant, a new row with a parent. The evidence is fixed in advance: the
# first min_sample entries that named the hypothesis when they were proposed (on or after its holdout date) and
# became trades, in the order they were proposed, so neither how fast a trade closed nor anything relabelled at
# review moves a trade in or out; excluded trades still count, and their stops are the proposal's, frozen. The
# approver moves it to testing, which counts it in the family; once every trade in the sample has closed with an
# R, the verdict is a function of rows alone: a centred-bootstrap test of mean R above zero against a Bonferroni
# bar of α over the hypotheses tested by the time the sample completed, frozen at the decision (or at a
# retirement, so a failed result is never buried). Accepting needs the verdict to clear the bar. Nothing here gates
# a setup or an order.
class Hypothesis < ApplicationRecord
  STATUSES = %w[ proposed testing accepted rejected retired ].freeze
  ALPHA = 0.05
  CLAIM = %i[ statement setup_id rules min_sample holdout_from expected_mean_r parent_id created_by_id ].freeze

  belongs_to :setup, optional: true
  belongs_to :parent, class_name: "Hypothesis", optional: true
  belongs_to :created_by, class_name: "User"
  belongs_to :tested_by, class_name: "User", optional: true
  belongs_to :decided_by, class_name: "User", optional: true
  has_many :variants, class_name: "Hypothesis", foreign_key: :parent_id, dependent: :restrict_with_exception, inverse_of: :parent
  has_many :order_proposals, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), prefix: true, validate: true

  attr_readonly(*CLAIM)

  validates :statement, :rules, :holdout_from, :expected_mean_r, presence: true
  validates :min_sample, numericality: { only_integer: true, in: 10..500 }
  validate :holdout_not_backdated, on: :create

  scope :ever_tested, -> { where.not(tested_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  def self.write!(claim, user:)
    create!(claim.merge(created_by: user)).tap do |hypothesis|
      AuditEvent.log("hypothesis_created", actor: :human, user: user, subject: hypothesis,
                     data: { statement: hypothesis.label, setup: hypothesis.setup&.name, min_sample: hypothesis.min_sample, holdout_from: hypothesis.holdout_from.iso8601,
                             expected_mean_r: hypothesis.expected_mean_r.to_s, parent: hypothesis.parent_id })
    end
  end

  # The bar a verdict must clear when tests hypotheses have been tested.
  def self.bar(tests) = ALPHA / [ tests, 1 ].max

  # Counted in the family from here on, whatever becomes of it.
  def test!(user:, reason:) = change_status!(:testing, from: %w[ proposed ], user: user, reason: reason) { { tested_at: Time.current, tested_by: user } }

  # Accept or reject on the verdict, frozen now.
  def decide!(decision:, user:, reason:)
    raise ArgumentError, "decide accept or reject" unless %w[ accepted rejected ].include?(decision.to_s)
    change_status!(decision, from: %w[ testing ], user: user, reason: reason) do
      verdict = verdict!
      raise ArgumentError, "the verdict does not clear the bar (p #{verdict["p_value"]} against #{verdict["bar"]}); it can be rejected or retired, not accepted" if decision.to_s == "accepted" && !verdict["clears"]
      { evidence: verdict, decided_at: Time.current, decided_by: user, decision_note: reason }
    end
  end

  # At any time; a hypothesis retired with its sample complete keeps the verdict it had, so a failure is on record.
  def retire!(user:, reason:)
    change_status!(:retired, from: %w[ proposed testing accepted rejected ], user: user, reason: reason) do
      status_testing? && ready? ? { evidence: verdict!, decided_at: Time.current, decided_by: user, decision_note: reason } : {}
    end
  end

  def label = statement.truncate(60)

  # Every named entry that became a trade on or after the holdout, in the order proposed; the sample is the first
  # min_sample of them.
  def evidence_trades
    @evidence_trades ||= Trade.joins(:order_proposal).merge(order_proposals.where(created_at: holdout_from.in_time_zone(MarketDay::ZONE).beginning_of_day..))
                              .order("order_proposals.created_at", "order_proposals.id").includes(:instrument).to_a
  end

  def sample = evidence_trades.first(min_sample)
  def scored = sample.select { it.closed? && it.realized_r }

  # Complete once the first min_sample trades exist and have all closed with an R, and no named entry proposed
  # before the last of them is still waiting to become a trade.
  def ready?
    return false unless sample.size == min_sample && sample.all? { it.closed? && it.realized_r }
    !order_proposals.occupying.where(created_at: ..sample.last.order_proposal.created_at).exists?
  end

  # Named entries that filled into a trade begun by another proposal: never evidence, so counted.
  def unlinked_fills = order_proposals.filled.where.not(id: Trade.where.not(order_proposal_id: nil).select(:order_proposal_id)).count

  def decided? = evidence.present?

  # The frozen verdict, else the one a decision now would freeze; nil until the sample is complete. A function of
  # rows alone, so what the page shows is what a decision writes.
  def verdict = @verdict ||= decided? ? evidence : (compute_verdict if ready?)

  private
    # The verdict from the rows as they stand under the lock.
    def verdict!
      @evidence_trades = @verdict = nil
      raise ArgumentError, "#{scored.size} of #{min_sample} trades closed with an R; no verdict yet" unless ready?
      compute_verdict
    end

    def compute_verdict
      completed_at = sample.map(&:closed_at).max
      tests = Hypothesis.where(tested_at: ..completed_at).or(Hypothesis.where(id: id)).count # itself always
      bar = self.class.bar(tests)
      r = sample.map { it.realized_r.to_f }
      test = Rails.cache.fetch([ "hypothesis-mean-test", Digest::SHA256.hexdigest([ r, bar ].to_json) ]) { Research::Stats.mean_test(r, alpha: bar) } # rows in, so the same answer
      p_value, lower_bound = test[:p_value].round(6), test[:lower_bound].round(4)
      { "n" => r.size, "mean_r" => test[:mean].round(4), "p_value" => p_value, "lower_bound" => lower_bound, "tests" => tests, "bar" => bar.round(6),
        "clears" => p_value <= bar.round(6) && lower_bound.positive?, "expected_mean_r" => expected_mean_r.to_f, "completed_at" => completed_at.iso8601,
        "r" => sample.to_h { [ it.id.to_s, it.realized_r.to_f ] }, "excluded_trade_ids" => sample.select(&:excluded_from_stats?).map(&:id) }
    end

    # One lock, one update, one audit row; the block works out the attributes under the lock.
    def change_status!(to, from:, user:, reason:)
      raise ArgumentError, "a reason is required" if reason.blank?
      transaction do
        lock!
        raise ArgumentError, "hypothesis #{id} is #{status}, not #{from.to_sentence(two_words_connector: " or ", last_word_connector: ", or ")}" unless from.include?(status)
        before = status
        attributes = block_given? ? yield : {}
        update!(attributes.merge(status: to))
        AuditEvent.log("hypothesis_status_changed", actor: :human, user: user, subject: self, reason: reason,
                       data: { from: before, to: status, tests: Hypothesis.ever_tested.count, verdict: attributes[:evidence] }.compact)
      end
      self
    end

    def holdout_not_backdated
      errors.add(:holdout_from, "cannot be before today: the evidence comes after the hypothesis") if holdout_from && holdout_from < MarketDay.today
    end
end
