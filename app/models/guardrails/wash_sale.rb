# Rule 6, both directions, taxable losses only (docs/phase-2-plan.md §0.11). A buy after a recent taxable loss
# on the same CUSIP cautions or blocks per the rule's mode; a sell that would realize a loss cautions when
# replacement shares were bought in either account within the window (the lot being sold is not a replacement).
# Instrument match only; a scale-out at a loss on a still-open trade carries no realized P&L and is not seen.
class Guardrails::WashSale < Guardrails::Rule
  def evaluate
    window = (rule.params["days"] || 30).to_i.days
    if proposal.buy?
      loss = context.account.trades.closed.where(instrument: proposal.instrument).where(closed_at: window.ago..).where("realized_pnl < 0").order(closed_at: :desc).first
      return pass unless loss
      detail = { loss_closed_at: loss.closed_at, loss: loss.realized_pnl, window_days: window / 1.day }
      rule.mode_block? ? block(**detail) : caution(**detail)
    else
      trade = context.open_trade_for(proposal.instrument)
      return pass unless trade&.avg_entry && proposal.limit_price && proposal.limit_price < trade.avg_entry
      own_lots = trade.trade_legs.where.not(activity_id: nil).pluck(:activity_id)
      replacements = Activity.fill.valid_for_journal.where(instrument: proposal.instrument, side: Schwab::Order::BUY, executed_at: window.ago..).where.not(id: own_lots).includes(:account)
      return pass(would_realize_loss: true) if replacements.none?
      caution(would_realize_loss: true, recent_buys: replacements.map { |b| { account: b.account.label, at: b.executed_at, quantity: b.quantity } })
    end
  end
end
