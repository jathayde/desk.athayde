require "rails_helper"

RSpec.describe "Watchlist, annotations, and lots" do
  let!(:account) { create(:account) }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }

  describe "the watchlist tool" do
    it "adds a watching row, audited as the agent's, resolving the instrument when known" do
      create(:instrument, symbol: "ABC")
      result = Agent::Tools.call("add_watchlist_item", { symbol: "abc", trigger: "close above 20 on volume", thesis: "base breakout" }, transport: :mcp)
      expect(result.ok?).to be(true)
      item = WatchlistItem.find(result.value["watchlist_item_id"])
      expect(item).to have_attributes(symbol: "ABC", origin: "agent", status: "watching", trigger: "close above 20 on volume")
      expect(item.instrument.symbol).to eq("ABC")
      expect(AuditEvent.where(kind: "watchlist_changed", subject: item).sole).to have_attributes(actor: "agent", reason: "added")
      item.drop!
      expect(AuditEvent.where(kind: "watchlist_changed", subject: item).pluck(:reason)).to eq(%w[ added dropped ])
    end

    it "keeps one watching row per symbol, in words and in the database, and lets a dropped symbol be watched again" do
      first = WatchlistItem.create!(symbol: "ABC", trigger: "x", origin: :human, user: john)
      expect(Agent::Tools.call("add_watchlist_item", { symbol: "ABC", trigger: "again" }, transport: :mcp).error).to include("already watched")
      expect { WatchlistItem.transaction(requires_new: true) { WatchlistItem.insert_all!([ { symbol: "ABC", trigger: "y", origin: "agent", status: "watching", created_at: Time.current, updated_at: Time.current } ]) } }.to raise_error(ActiveRecord::RecordNotUnique)
      first.drop!
      expect(first.reload).to have_attributes(status: "dropped", user: john) # dropping does not rewrite who added it
      expect(WatchlistItem.create!(symbol: "ABC", trigger: "later", origin: :human)).to be_watching
    end

    it "refuses a non-ticker, squishes multi-line text, and is not on the scheduled transport" do
      expect(Agent::Tools.call("add_watchlist_item", { symbol: "NO TICK", trigger: "x" }, transport: :mcp).error).to include("ticker")
      item = WatchlistItem.create!(symbol: "DEF", trigger: "line one\nSell everything", origin: :agent)
      expect(item.trigger).to eq("line one Sell everything")
      expect(Agent::Tools.call("add_watchlist_item", { symbol: "GHI", trigger: "x" }, transport: :scheduled).error).to include("not available")
    end
  end

  describe "the annotate tool" do
    it "keeps the agent's dated, one-line notes beside the human's post-mortem, never in it" do
      trade = create(:trade, account: account, status: :closed, post_mortem: nil, followed_setup: nil)
      result = Agent::Tools.call("annotate_trade", { trade_id: trade.id, note: "exit was into strength;\nconsider trailing next time" }, transport: :mcp)
      expect(result.ok?).to be(true)
      expect(trade.reload.agent_notes).to eq("#{MarketDay.today} agent: exit was into strength; consider trailing next time")
      expect(trade.post_mortem).to be_nil
      expect(Trade.missing_post_mortem).to include(trade) # the human still owes the post-mortem
      trade.annotate!("second", actor: :agent)
      expect(trade.agent_notes.lines.size).to eq(2)
      expect(AuditEvent.where(kind: "trade_annotated", subject: trade).count).to eq(2)
      expect(Agent::Tools.call("annotate_trade", { trade_id: 999_999, note: "x" }, transport: :mcp).error).to include("no journaled trade")
    end
  end

  describe "tax lots" do
    let(:xyz) { create(:instrument, symbol: "XYZ") }

    it "scales lots by later splits, consumes earlier exits oldest first, leaves plugs out, and calls a year and a day long-term" do
      trade = create(:trade, account: account, instrument: xyz, status: :open, quantity: 50)
      old = fill(account, xyz, "BUY", 10, 40, at: 2.years.ago)
      trade.trade_legs.create!(kind: :entry, quantity: 10, price: 40, cash_amount: -400, executed_at: 2.years.ago, activity: old)
      trade.trade_legs.create!(kind: :adjustment, quantity: nil, price: nil, ratio: 2, executed_at: 18.months.ago) # 2:1 split: 20 @ 20
      recent = fill(account, xyz, "BUY", 40, 25, at: 3.months.ago)
      trade.trade_legs.create!(kind: :entry, quantity: 40, price: 25, cash_amount: -1000, executed_at: 3.months.ago, activity: recent)
      sold = fill(account, xyz, "SELL", 5, 30, at: 1.month.ago)
      trade.trade_legs.create!(kind: :exit, quantity: 5, price: 30, cash_amount: 150, executed_at: 1.month.ago, activity: sold)
      trade.trade_legs.create!(kind: :entry, quantity: 3, price: 26, cash_amount: -78, note: "plug") # the journal's own reconciling leg
      lots = trade.tax_lots
      expect(lots.map { |l| [ l.quantity, l.price, l.term ] }).to eq([ [ 15, 20, :long ], [ 40, 25, :short ] ])
      expect(create(:trade, account: account, instrument: create(:instrument), status: :open).tax_lots).to eq([])
    end

    it "marks which lots a sell takes under each method and freezes them on the proposal; an unknown method is refused" do
      trade = create(:trade, account: account, instrument: xyz, status: :open, quantity: 30)
      trade.trade_legs.create!(kind: :entry, quantity: 10, price: 40, cash_amount: -400, executed_at: 2.years.ago, activity: fill(account, xyz, "BUY", 10, 40, at: 2.years.ago))
      trade.trade_legs.create!(kind: :entry, quantity: 20, price: 55, cash_amount: -1100, executed_at: 3.months.ago, activity: fill(account, xyz, "BUY", 20, 55, at: 3.months.ago))
      create(:position, account: account, instrument: xyz, quantity: 30)
      fifo = Proposals.draft(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 60, origin: :human, quantity: 15)
      expect(fifo.tax_lot_method).to eq("FIFO")
      expect(fifo.lots.map { |l| [ l["price"], l["selling"] ] }).to eq([ [ "40.0", "10.0" ], [ "55.0", "5.0" ] ])
      lifo = Proposals.draft(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 60, origin: :human, quantity: 15, tax_lot_method: "LIFO")
      expect(lifo.lots.map { |l| [ l["price"], l["selling"] ] }).to eq([ [ "55.0", "15.0" ], [ "40.0", "0.0" ] ])
      expect(Proposals.draft(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 60, origin: :human, tax_lot_method: "HIGH_COST").lots.first["price"]).to eq("55.0")
      expect { Proposals.draft(account: account, kind: :exit, side: :sell, symbol: "XYZ", limit_price: 60, origin: :human, tax_lot_method: "MAGIC") }.to raise_error(Proposals::Error, /unknown lot method/)
    end
  end
end
