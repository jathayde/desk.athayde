# One scheduled conversation with the model: what it served, how it ended, what it cost, and what it said.
class AgentRun < ApplicationRecord
  STALE_AFTER = 20.minutes # a running row older than the wall-clock deadline is a killed worker, not a run
  TITLES = { "morning_brief" => "morning brief", "eod" => "end of day", "sunday_review" => "Sunday review" }.freeze

  has_many :tool_calls, dependent: :nullify

  enum :kind, { morning_brief: "morning_brief", eod: "eod", sunday_review: "sunday_review" }
  # capped: the turn, call, or token budget ended the loop but the model had written something.
  # skipped: nothing to do (a closed market day), so nothing to email.
  enum :status, { running: "running", succeeded: "succeeded", capped: "capped", failed: "failed", skipped: "skipped" }

  scope :recent_first, -> { order(started_at: :desc, id: :desc) }
  scope :this_month, -> { where(started_at: Time.current.in_time_zone(MarketDay::ZONE).beginning_of_month..) }
  scope :stale_running, -> { running.where(started_at: ..STALE_AFTER.ago) }
  scope :unemailed, -> { where(status: %w[ succeeded capped failed ]).where(emailed_at: nil) }

  # A row a killed worker left running does not count as served: the retry after a deploy still briefs.
  def self.served?(kind, date) = where(kind: kind, market_date: date).where.not(status: :failed).where.not(id: stale_running).exists?

  # A worker killed mid-run leaves a running row; the next scheduled job and the digest both sweep it.
  def self.sweep_stale!
    stale_running.find_each { |run| run.finish!(:failed, error: "left running") }
  end

  def finish!(status, error: nil, **attributes)
    update!(status: status, error: error, finished_at: Time.current, **attributes)
  end

  # The email for this run, whatever happened to it; never a second API call.
  def deliver!
    raise ArgumentError, "#{title} is #{status}; nothing to send" if running? || skipped?
    (sunday_review? ? BriefMailer.sunday_review(self) : BriefMailer.brief(self)).deliver_now
    update!(emailed_at: Time.current)
  end

  def brief? = morning_brief? || eod?
  def delivered? = emailed_at.present?
  def deliverable? = !running? && !skipped?
  def total_input_tokens = [ input_tokens, cache_creation_input_tokens, cache_read_input_tokens ].compact.sum
  def unpriced? = model.present? && estimated_cost.nil? && !skipped?

  def title
    day = (market_date || started_at&.in_time_zone(MarketDay::ZONE))&.strftime("%a %b %-d")
    [ TITLES.fetch(kind), day ].compact.join(", ")
  end
end
