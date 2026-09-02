# The email around a run's text: subject, token line, degraded reasons, as-of stamps, the deterministic
# sections (fills, journal rows, post-mortems, snapshot), and the footer. Nothing here comes from the model.
class Brief
  LIST_LIMIT = 10

  def initialize(run)
    @run = run
    @dashboard = Dashboard.new
  end

  attr_reader :run
  delegate :kind, :market_date, :degraded_reasons, :output_markdown, to: :run

  def account = @dashboard.account
  def date = market_date || Time.current.in_time_zone(MarketDay::ZONE).to_date

  def subject
    prefix = run.failed? ? "FAILED" : run.capped? ? "CAPPED" : run.degraded? ? "DEGRADED" : nil
    [ prefix, "Athayde Desk: #{run.title}" ].compact.join(": ")
  end

  def token_line
    status = SchwabToken.status
    token = SchwabToken.current
    return "Schwab: #{status}" unless token && status.in?(%i[ healthy expiring ])
    "Schwab: #{status}, token expires #{stamp(token.refresh_expires_at, date: true)}"
  end

  def as_of_lines
    return [ "No trading account is set up." ] unless account
    SyncRun::ACCOUNT_FEEDS.map { |feed| "#{feed.to_s.humanize}: #{stamp(account.last_sync(feed))}" }
  end

  def unavailable = run.failed? ? "The brief is unavailable: #{run.error}" : nil
  def cut_off = run.stop_reason == "max_tokens" ? "The model's output was cut off; what follows is incomplete." : nil
  def body = output_markdown.to_s.strip

  # End-of-day sections, from the database. Only fills the journal would accept count as fills, and while the
  # activities feed is stale the database cannot say what filled today: nil, rendered as unknown, not "none".
  def activities_stale? = account.nil? || @dashboard.stale?(account.last_sync(:activities), :activities)
  def fills_today = @fills_today ||= activities_stale? ? nil : account.activities.fill.valid_for_journal.where(executed_at: day_range).chronological.includes(:instrument).to_a
  def trades_touched_today = @trades_touched_today ||= activities_stale? ? nil : account.trades.where(updated_at: day_range).includes(:instrument, :setup).order(:id).to_a
  def balance_stale? = @dashboard.balance_stale?
  def missing_post_mortems = @missing_post_mortems ||= Trade.journaled.missing_post_mortem.includes(:instrument).order(closed_at: :desc).limit(LIST_LIMIT).to_a
  def missing_post_mortem_count = @missing_post_mortem_count ||= Trade.journaled.missing_post_mortem.count
  def more_post_mortems = [ missing_post_mortem_count - missing_post_mortems.size, 0 ].max
  def snapshot = account && account.snapshots.find_by(as_of: date)
  def balance = @dashboard.balance

  def footer
    parts = [ "#{run.tool_turns} #{'turn'.pluralize(run.tool_turns)}", "#{run.tool_calls_count} tool #{'call'.pluralize(run.tool_calls_count)}",
              "#{run.total_input_tokens} in / #{run.output_tokens.to_i} out tokens" ]
    parts << (run.estimated_cost ? "$#{'%.4f' % run.estimated_cost}" : "unpriced")
    parts << "stopped: #{run.stop_reason}" if !run.failed? && run.stop_reason.present? && run.stop_reason != "end_turn"
    parts << run.error if run.capped? && run.error.present?
    parts.join(" · ")
  end

  def stamp(time, date: false) = time ? time.in_time_zone(MarketDay::ZONE).strftime(date ? "%a %b %-d, %-l:%M %p" : "%a %-l:%M %p") : "never"

  private
    def day_range = date.in_time_zone(MarketDay::ZONE).all_day
end
