require "rails_helper"

RSpec.describe Trade::Costs do
  let(:account) { create(:account) }
  let(:xyz) { create(:instrument, symbol: "XYZ") }
  let(:approved_at) { Time.zone.parse("2026-10-14 10:00:00 -0400") }
  let(:quote) { { "bid" => "49.90", "ask" => "50.10", "mark" => "50.00", "fetched_at" => approved_at.iso8601, "stale" => false } }

  # An entry of 100 at the given fill, approved against the quote, closed by a stop order (in parts if asked) or a
  # limit exit.
  def trade(fill: 50.20, limit: 50.25, filled_at: approved_at + 5.minutes, shadow: false, stop_fills: nil, stop_price: 47, exit_fill: 56, quote: self.quote, proposal: true)
    proposal = create(:order_proposal, account: account, instrument: xyz, status: "filled", limit_price: limit, stop_price: 47, shadow: shadow, decided_at: approved_at, quote_at_approval: quote) if proposal
    trade = create(:trade, account: account, instrument: xyz, order_proposal: proposal, planned_stop: 47)
    entry = create(:activity, account: account, instrument: xyz, quantity: 100, price: fill, executed_at: filled_at, broker_order_id: "E#{SecureRandom.hex(4)}", trade_date: filled_at.to_date)
    trade.trade_legs.create!(activity: entry, kind: "entry", quantity: 100, price: fill, executed_at: filled_at, cash_amount: -100 * fill)
    exit_id = "X#{SecureRandom.hex(4)}"
    order = create(:order, account: account, instrument: xyz, side: "SELL", order_type: stop_fills ? "STOP" : "LIMIT", stop_price: (stop_price if stop_fills), broker_order_id: exit_id, quantity: 100)
    (stop_fills || [ [ 100, exit_fill ] ]).each_with_index do |(quantity, price), i|
      at = filled_at + 2.days + i.minutes
      exit = create(:activity, account: account, instrument: xyz, side: "SELL", quantity: quantity, price: price, executed_at: at, broker_order_id: exit_id, order: order, trade_date: at.to_date)
      trade.trade_legs.create!(activity: exit, kind: "exit", quantity: quantity, price: price, executed_at: at, cash_amount: quantity * price)
    end
    trade.recompute!
    trade
  end

  it "measures a marketable entry filled in its approval session against the frozen mid, and adds it back for gross R" do
    t = trade
    expect(t.slippage["entry"]).to include("tag" => "comparable", "mid" => "50.0", "fill" => "50.2", "per_share" => "0.2", "dollars" => "20.0")
    expect(t.realized_r).to be_within(0.0001).of((56 - 50.20) * 100 / (3.20 * 100))
    expect(t.gross_r).to eq((t.realized_r + BigDecimal(t.slippage["entry"]["r"])).round(4))
  end

  it "measures every fill of a stop-out against the stop that triggered, a trailed one included" do
    t = trade(stop_fills: [ [ 60, 46.80 ], [ 40, 46.50 ] ])
    expect(t.slippage["stop"]).to include("tag" => "comparable", "stop" => "47.0", "fill" => "46.68", "dollars" => "32.0")
    trailed = trade(stop_fills: [ [ 100, 51.90 ] ], stop_price: 52)
    expect(trailed.slippage["stop"]).to include("per_share" => "0.1", "dollars" => "10.0") # 52 against 51.90, never the planned 47
    expect(trailed.gross_r).to be > trailed.realized_r
  end

  it "tags a resting limit, a stale quote, a later session, and a shadow placement as not costs, and gives none of them a gross R" do
    expect(trade(limit: 49.50, fill: 49.50).slippage["entry"]["tag"]).to eq("not_comparable") # below the ask: it waited for the market
    expect(trade(quote: quote.merge("stale" => true)).slippage["entry"]["tag"]).to eq("not_comparable")
    expect(trade(filled_at: approved_at + 1.day).slippage["entry"]["tag"]).to eq("not_comparable")
    shadowed = trade(shadow: true, stop_fills: [ [ 100, 46.50 ] ])
    expect(shadowed.slippage.values.map { it["tag"] }).to eq(%w[ shadow shadow ])
    expect(shadowed.gross_r).to be_nil
    expect(trade(quote: { "unavailable" => "rate limited", "fetched_at" => approved_at.iso8601 }).slippage["entry"]).to eq("tag" => "unavailable", "reason" => "rate limited")
  end

  it "measures nothing on a trade that came from no proposal" do
    t = trade(proposal: false, stop_fills: [ [ 100, 46.50 ] ])
    expect(t.slippage).to be_nil
    expect(t.gross_r).to be_nil
  end

  it "gives a setup its gross average beside the realized average over the same trades" do
    setup = create(:setup)
    measured = trade
    unmeasured = trade(shadow: true)
    [ measured, unmeasured ].each { it.update!(setup: setup, needs_review: false) }
    setup.recompute_stats!
    expect(setup).to have_attributes(sample_size: 2, cost_sample_size: 1, gross_avg_r: measured.gross_r, costed_avg_r: measured.realized_r.round(4))
  end
end
