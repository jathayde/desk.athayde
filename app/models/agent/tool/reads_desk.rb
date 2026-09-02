# For tools that read the desk through its read model instead of re-deriving freshness rules.
module Agent::Tool::ReadsDesk
  private
    def desk = @desk ||= Desk.new
    def account = desk.account
    def stamp(time, stale) = { as_of: time, stale: stale }
end
