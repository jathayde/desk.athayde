# For tools that read the desk through the Dashboard read model instead of re-deriving freshness rules.
module Agent::Tool::Desk
  private
    def dashboard = @dashboard ||= Dashboard.new
    def account = dashboard.account
    def stamp(time, stale) = { as_of: time, stale: stale }
end
