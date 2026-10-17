# What the model is told before it asks anything: the desk's freshness, the token, the calendar, the memory
# files, and every reason the run is already degraded. Computed once per run from the database alone.
class Agent::Context
  def initialize(kind:, date:, memory: Memory::Repo.configured, proposal: nil)
    @kind, @date, @memory, @proposal = kind, date, memory, proposal
    @desk = Desk.new
  end

  attr_reader :kind, :date, :memory, :desk, :proposal

  def account = desk.account
  def market_day = @market_day ||= MarketDay.find_by(date: date)
  def token_status = desk.token_status

  def as_of
    @as_of ||= {
      positions: account&.last_sync(:positions), orders: account&.last_sync(:orders), activities: account&.last_sync(:activities),
      calendar: market_day&.source, memory: memory.last_modified_at, memory_sha: memory.head_sha
    }
  end

  # Reasons known before the first call; the run adds what the tools report.
  def degraded_reasons
    @degraded_reasons ||= [].tap do |reasons|
      reasons << "Schwab token #{token_status}: nothing has synced since #{desk.sync_paused_since&.in_time_zone(MarketDay::ZONE)&.strftime('%a %-l:%M %p') || 'the token died'}" unless SchwabToken.usable?
      reasons << "calendar unverified (Schwab hours unavailable); today may be a holiday" if market_day&.fallback?
      reasons << "positions are stale (last sync #{stamp(as_of[:positions])})" if desk.balance_stale?
      reasons << "orders are stale (last sync #{stamp(as_of[:orders])}); stop and protection states may be wrong" if account && desk.stale?(as_of[:orders], :orders)
      reasons << "activities are stale (last sync #{stamp(as_of[:activities])}); fills and journal rows may be missing" if account && desk.stale?(as_of[:activities], :activities)
      reasons << "no trading account is set up yet" if account.nil?
      reasons << "memory repo missing at #{memory.path || 'unset MEMORY_REPO_PATH'}" unless memory.present?
      reasons << "memory repo has none of its files at #{memory.path}" if memory.empty?
      reasons << "memory files unreadable: #{memory.unreadable.join(', ')}" if memory.unreadable.any?
      reasons << "memory files truncated: #{memory.truncated.join(', ')}" if memory.truncated.any?
    end
  end

  def watchlist = @watchlist ||= WatchlistItem.current.to_a
  def stop_suggestions = @stop_suggestions ||= (account ? account.positions.suggesting_a_stop.includes(:working_stop_order).select(&:stop_suggestion) : [])

  # Held and delisted: an instrument the desk no longer holds is nobody's business in a brief.
  def delisted_symbols
    @delisted_symbols ||= account ? desk.rows.filter_map { |r| r.position.instrument.symbol if r.protection == :delisted } : []
  end

  # The same numbers the get_setup_stats tool returns, serialized the same way (decimal strings, never BigDecimal#to_s).
  def setup_stats = @setup_stats ||= Agent.serialize(Setup.agent_stats).deep_symbolize_keys

  # The day's proposal traffic for the recap: decided today, or given a broker outcome today (by the audit row
  # the sync wrote, not by updated_at, which any touch moves).
  def todays_proposals
    @todays_proposals ||= begin
      day = date.in_time_zone(MarketDay::ZONE).all_day
      outcomes = AuditEvent.where(kind: %w[ proposal_filled proposal_cancelled ], subject_type: "OrderProposal", created_at: day).select(:subject_id)
      OrderProposal.includes(:instrument).where(decided_at: day).or(OrderProposal.where(id: outcomes)).order(:id).to_a
    end
  end

  def stamp(time) = time ? I18n.l(time, format: :connection) : "never"
  def percent(ratio) = ratio ? "#{(BigDecimal(ratio.to_s) * 100).round(1).to_s('F')}%" : "n/a"
  # One line of data, never a line break: a symbol is Schwab's, and the prompt's structure is ours.
  def single_line(text) = text.to_s.gsub(/[\r\n]+/, " ")
  # Free text as a quoted string, so nothing in it can pass for the prompt's own lines.
  def quoted(text, limit: 200) = single_line(text).truncate(limit).to_json

  def guardrail_summary
    return "rejected by rules" if proposal.rejected_by_rules?
    proposal.warnings.any? ? "cautions on #{proposal.warnings.join(", ")}" : "no cautions"
  end

  # Rendered once per run: the same bytes on every turn is what makes the prompt cache hit.
  def system_prompt = @system_prompt ||= render(system_template)
  def user_prompt = @user_prompt ||= render(kind.to_s)

  private
    # The skeptic has a job of its own; every other run shares the brief's frame.
    def system_template = kind.to_s == "skeptic" ? "skeptic_system" : "system"

    def render(name)
      template = Rails.root.join("app/models/agent/prompts/#{name}.md.erb").read
      ERB.new(template, trim_mode: "-").result(binding)
    end
end
