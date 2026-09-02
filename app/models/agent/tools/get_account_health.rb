class Agent::Tools::GetAccountHealth < Agent::Tool
  include Agent::Tool::ReadsDesk

  tool description: "System and account health: Schwab token status and expiry, sync status per feed, pause reason, shadow mode, manual halt, " \
                    "equity, settled and unsettled cash, drawdown from the latest snapshot, and the positions excluded from open risk by reason.",
       output: { state: { type: "string" }, shadow_mode: { type: "boolean" }, halted: { type: "boolean" }, halt_reason: { type: [ "string", "null" ] },
                 token: { type: "object" }, sync: { type: "object" }, equity: { type: [ "object", "null" ] }, drawdown: { type: [ "object", "null" ] },
                 excluded_from_open_risk: { type: [ "object", "null" ] }, trades_needing_review: { type: "integer" } }

  def call
    token = desk.token
    {
      state: desk.state, shadow_mode: SystemSettings.instance.shadow_mode, halted: desk.halted?, halt_reason: desk.halt_reason,
      token: { status: desk.token_status, issued_at: token&.issued_at, refresh_expires_at: token&.refresh_expires_at,
               next_sunday_email: SchwabToken.next_sunday_email, last_refresh_error: token&.last_refresh_error },
      sync: { paused_reason: desk.sync_paused_reason, paused_since: desk.sync_paused_since, last_failure: last_failure, feeds: feeds },
      equity: equity, drawdown: drawdown, excluded_from_open_risk: desk.ready? ? desk.excluded_by_reason : nil,
      trades_needing_review: desk.review_count
    }
  end

  private
    def feeds
      return {} unless account
      SyncRun::ACCOUNT_FEEDS.to_h { |feed| [ feed, { last_success_at: account.last_sync(feed), unresolved_failure: desk.unresolved_failure(feed)&.error } ] }
    end

    def last_failure
      run = desk.sync_failure
      run && { feed: run.feed, at: run.started_at, error: run.error }
    end

    def equity
      balance = desk.balance or return nil
      { value: balance.equity, settled_cash: balance.settled_cash, unsettled_cash: balance.unsettled_cash,
        day_change: desk.day_change, day_change_label: desk.day_change_label, **stamp(balance.as_of, desk.balance_stale?) }
    end

    def drawdown
      snapshot = desk.latest_snapshot or return nil
      { as_of: snapshot.as_of, drawdown: snapshot.drawdown, index_value: snapshot.index_value, high_water_index: snapshot.high_water_index }
    end
end
