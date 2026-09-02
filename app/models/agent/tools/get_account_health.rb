class Agent::Tools::GetAccountHealth < Agent::Tool
  include Agent::Tool::Desk

  tool description: "System and account health: Schwab token status and expiry, sync status per feed, pause reason, shadow mode, manual halt, " \
                    "equity, settled and unsettled cash, drawdown from the latest snapshot, and unprotected position counts by reason.",
       output: { state: { type: "string" }, shadow_mode: { type: "boolean" }, halted: { type: "boolean" }, halt_reason: { type: [ "string", "null" ] },
                 token: { type: "object" }, sync: { type: "object" }, equity: { type: [ "object", "null" ] }, drawdown: { type: [ "object", "null" ] },
                 unprotected: { type: [ "object", "null" ] }, trades_needing_review: { type: "integer" } }

  def call
    token = dashboard.token
    {
      state: dashboard.state, shadow_mode: SystemSettings.instance.shadow_mode, halted: dashboard.halted?, halt_reason: dashboard.halt_reason,
      token: { status: dashboard.token_status, issued_at: token&.issued_at, refresh_expires_at: token&.refresh_expires_at,
               next_sunday_email: SchwabToken.next_sunday_email, last_refresh_error: token&.last_refresh_error },
      sync: { paused_reason: dashboard.sync_paused_reason, paused_since: dashboard.sync_paused_since, last_failure: last_failure, feeds: feeds },
      equity: equity, drawdown: drawdown, unprotected: dashboard.ready? ? dashboard.excluded_by_reason : nil,
      trades_needing_review: dashboard.review_count
    }
  end

  private
    def feeds
      return {} unless account
      SyncRun::ACCOUNT_FEEDS.to_h { |feed| [ feed, { last_success_at: account.last_sync(feed), last_failure: account.last_sync_failure(feed)&.error } ] }
    end

    def last_failure
      run = dashboard.sync_failure
      run && { feed: run.feed, at: run.started_at, error: run.error }
    end

    def equity
      balance = dashboard.balance or return nil
      { value: balance.equity, settled_cash: balance.settled_cash, unsettled_cash: balance.unsettled_cash,
        day_change: dashboard.day_change, day_change_label: dashboard.day_change_label, **stamp(balance.as_of, dashboard.balance_stale?) }
    end

    def drawdown
      snapshot = dashboard.latest_snapshot or return nil
      { as_of: snapshot.as_of, drawdown: snapshot.drawdown, index_value: snapshot.index_value, high_water_index: snapshot.high_water_index }
    end
end
