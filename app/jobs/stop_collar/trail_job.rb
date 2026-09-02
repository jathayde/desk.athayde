module StopCollar
  # 16:10 New York on trading days, after the close and before the end-of-day brief: recompute the trails for
  # every protected position on the trading account and keep the tightest one above the working stop as a
  # suggestion. A spent Schwab budget ends the run and leaves yesterday's suggestions to age out; nothing is placed.
  class TrailJob < ApplicationJob
    limits_concurrency to: 1, key: ->(*) { self.class.name }, on_conflict: :discard

    def perform(date = MarketDay.today)
      return unless MarketDay.for(date).trading?
      Account.trading.find_each do |account|
        setups = account.trades.open.includes(:setup).index_by(&:instrument_id)
        account.positions.where.not(id: account.positions.suggestable).update_all(suggested_stop: nil, suggested_stop_method: nil, suggested_at: nil) # nothing to tighten any more
        account.positions.suggestable.includes(:instrument, :working_stop_order).each do |position|
          params = RiskRule.params_for("stop_collar", setup: setups[position.instrument_id]&.setup)
          suggestion = StopCollar::Trail.new(position, params: params).suggestion
          position.update!(suggested_stop: suggestion&.price, suggested_stop_method: suggestion&.strategy, suggested_at: suggestion && Time.current)
        end
      end
    rescue Schwab::RateLimited => e
      Rails.error.report(e, handled: true, context: { job: self.class.name }) # the rest keep yesterday's suggestion until it ages out
    end
  end
end
