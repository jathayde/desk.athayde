# What the model is told before it asks anything: the desk's freshness, the token, the calendar, the memory
# files, and every reason the run is already degraded. Computed once per run from the database alone.
class Agent::Context
  def initialize(kind:, date:, memory: Memory::Repo.configured)
    @kind, @date, @memory = kind, date, memory
    @dashboard = Dashboard.new
  end

  attr_reader :kind, :date, :memory, :dashboard

  def account = dashboard.account
  def market_day = @market_day ||= MarketDay.find_by(date: date)
  def token_status = dashboard.token_status

  def as_of
    @as_of ||= {
      positions: account&.last_sync(:positions), orders: account&.last_sync(:orders), activities: account&.last_sync(:activities),
      calendar: market_day&.source, memory: memory.last_modified_at, memory_sha: memory.head_sha
    }
  end

  # Reasons known before the first call; the run adds what the tools report.
  def degraded_reasons
    @degraded_reasons ||= [].tap do |reasons|
      reasons << "Schwab token #{token_status}: nothing has synced since #{dashboard.sync_paused_since&.in_time_zone(MarketDay::ZONE)&.strftime('%a %-l:%M %p') || 'the token died'}" unless SchwabToken.usable?
      reasons << "calendar unverified (Schwab hours unavailable); today may be a holiday" if market_day&.fallback?
      reasons << "positions are stale (last sync #{stamp(as_of[:positions])})" if dashboard.balance_stale?
      reasons << "orders are stale (last sync #{stamp(as_of[:orders])}); stop and protection states may be wrong" if account && dashboard.stale?(as_of[:orders], :orders)
      reasons << "no trading account is set up yet" if account.nil?
      reasons << "memory repo missing at #{memory.path || 'unset MEMORY_REPO_PATH'}" unless memory.present?
      reasons << "memory repo has none of its files at #{memory.path}" if memory.empty?
      reasons << "memory files unreadable: #{memory.unreadable.join(', ')}" if memory.unreadable.any?
      reasons << "memory files truncated: #{memory.truncated.join(', ')}" if memory.truncated.any?
    end
  end

  # The same numbers the get_setup_stats tool returns, serialized the same way (decimal strings, never BigDecimal#to_s).
  def setup_stats = @setup_stats ||= Agent.serialize(Agent::Tools::GetSetupStats.new.call).deep_symbolize_keys

  def stamp(time) = time ? time.in_time_zone(MarketDay::ZONE).strftime("%a %b %-d, %-l:%M %p %Z") : "never"
  def percent(ratio) = ratio ? "#{(BigDecimal(ratio.to_s) * 100).round(1).to_s('F')}%" : "n/a"

  # Rendered once per run: the same bytes on every turn is what makes the prompt cache hit.
  def system_prompt = @system_prompt ||= render("system")
  def user_prompt = @user_prompt ||= render(kind.to_s)

  private
    def render(name)
      template = Rails.root.join("app/models/agent/prompts/#{name}.md.erb").read
      ERB.new(template, trim_mode: "-").result(binding)
    end
end
