require "rails_helper"

RSpec.describe "Sync feeds" do
  let(:fake) { Schwab::FakeClient.instance }
  let!(:token) { create(:schwab_token) }
  let(:hash) { Schwab::FakeClient::ACCOUNT_HASH }

  describe Sync::AccountsJob do
    it "discovers accounts by hash as read-only and unclassified" do
      described_class.perform_now
      account = Account.find_by!(schwab_hash: hash)
      expect(account).to have_attributes(trading_enabled: false, account_type: nil)
      expect(SyncRun.last).to be_succeeded.and have_attributes(records_touched: 1)
      described_class.perform_now
      expect(Account.count).to eq(1)
    end
  end

  describe Sync::PositionsJob do
    let!(:account) { create(:account, schwab_hash: hash) }

    it "upserts positions and instruments, records a balance, and derives last price" do
      described_class.perform_now(account)
      expect(account.positions.count).to eq(3)
      xyz = account.positions.joins(:instrument).find_by(instruments: { symbol: "XYZ" })
      expect(xyz).to have_attributes(quantity: 40, average_price: BigDecimal("51.18"), last_price: BigDecimal("53"))
      expect(xyz.instrument.cusip).to eq("037833100")
      expect(account.current_balance).to have_attributes(equity: BigDecimal("6508.55"), settled_cash: BigDecimal("2110"))
      expect(SyncRun.last).to be_succeeded
    end

    it "deletes positions the broker no longer reports, but only on a complete run" do
      gone = create(:position, account: account)
      described_class.perform_now(account)
      expect(Position.exists?(gone.id)).to be(false)
      stale = create(:position, account: account)
      fake.enqueue(:account) { raw = fake.account(hash); raw["securitiesAccount"]["positions"][0]["instrument"] = { "assetType" => "EQUITY" }; raw }
      described_class.perform_now(account)
      expect(Position.exists?(stale.id)).to be(true)
      expect(SyncRun.last).to be_partial
      expect(SyncRun.last.unmapped_values.keys).to eq([ "positions_unresolved" ])
    end

    it "refuses an empty positions list against positive long market value" do
      create(:position, account: account)
      fake.enqueue(:account) { raw = fake.account(hash); raw["securitiesAccount"].delete("positions"); raw }
      described_class.perform_now(account)
      expect(SyncRun.last).to be_failed
      expect(account.positions.count).to eq(1)
    end

    it "ignores zero-quantity positions and records cost basis" do
      fake.enqueue(:account) { raw = fake.account(hash); raw["securitiesAccount"]["positions"][2]["longQuantity"] = 0; raw }
      described_class.perform_now(account)
      expect(account.positions.count).to eq(2)
      expect(account.positions.joins(:instrument).find_by!(instruments: { symbol: "XYZ" }).cost_basis).to eq(BigDecimal("2047.2"))
    end

    it "records token loss as skipped rather than failed" do
      token.update!(revoked_at: Time.current)
      allow(Rails.configuration.x.schwab).to receive(:adapter).and_return(:http)
      described_class.perform_now(account)
      expect(SyncRun.last).to be_skipped_token
    end
  end

  describe Sync::OrdersJob do
    let!(:account) { create(:account, schwab_hash: hash, trading_enabled: true) }

    before { Sync::PositionsJob.perform_now(account) }

    it "flattens brackets and replacements with lineage, then assigns working stops" do
      described_class.perform_now(account)
      expect(account.orders.count).to eq(4)
      child = account.orders.find_by!(broker_order_id: "1004055538124")
      expect(child.parent_order.broker_order_id).to eq("1004055538123")
      replacement = account.orders.find_by!(broker_order_id: "1004055538201")
      expect(replacement.replaces_order.broker_order_id).to eq("1004055538200")
      expect(child.instrument.cusip).to eq("037833100")
      xyz = account.positions.joins(:instrument).find_by!(instruments: { symbol: "XYZ" })
      expect(xyz.working_stop_order).to eq(child)
      expect(xyz.protection).to eq(:protected)
      def_position = account.positions.joins(:instrument).find_by!(instruments: { symbol: "DEF" })
      expect(def_position.working_stop_order).to eq(replacement)
      expect(SyncRun.last).to be_succeeded.and have_attributes(records_touched: 4)
    end

    it "backfills a year on the first run and overlaps the cursor by a day afterwards" do
      described_class.perform_now(account)
      first = fake.calls.find { |c| c.first == :orders }
      expect(first[2]).to be_within(2.seconds).of(364.days.ago)
      fake.reset!
      travel 2.hours
      described_class.perform_now(account)
      second = fake.calls.find { |c| c.first == :orders }
      expect(second[2]).to be_within(2.seconds).of(SyncRun.for(:orders, account).advanced_cursor.order(:started_at).first.window_to - 1.day)
    end

    it "re-fetches a working stop that fell out of the list before giving it up" do
      described_class.perform_now(account)
      fake.enqueue(:orders) { [] }
      described_class.perform_now(account)
      expect(fake.calls.map(&:first)).to include(:order)
      xyz = account.positions.joins(:instrument).find_by!(instruments: { symbol: "XYZ" })
      expect(xyz.working_stop_order).to be_present
    end

    it "marks a stop gone when Schwab no longer returns it even by id, and drops the protection" do
      described_class.perform_now(account)
      fake.enqueue(:orders) { [] }
      fake.enqueue(:order, sticky: true) { raise Schwab::RequestError.new("Not Found", status: 400) }
      described_class.perform_now(account)
      xyz = account.positions.joins(:instrument).find_by!(instruments: { symbol: "XYZ" })
      expect(xyz.working_stop_order).to be_nil
      expect(account.orders.where(status: Schwab::Order::GONE).count).to eq(2)
      expect(SyncRun.last).to be_partial
      expect(SyncRun.last.unmapped_values.keys).to eq([ "stops_gone" ])
    end

    it "quarantines one malformed order and keeps the rest" do
      fake.enqueue(:orders) { fake.orders(hash, from: 1.day.ago) + [ { "status" => "FILLED" } ] }
      described_class.perform_now(account)
      expect(account.orders.count).to eq(4)
      expect(SyncRun.last).to be_partial
      expect(SyncRun.last.unmapped_values["orders_unmapped"].first).to include("orderId")
    end

    it "runs the WORKING pass once per day" do
      described_class.perform_now(account)
      described_class.perform_now(account)
      described_class.perform_now(account)
      expect(fake.calls.count { |c| c.first == :orders && c.last == Schwab::Order::WORKING }).to eq(1)
    end

    it "never nulls lineage or a proposal link on a later upsert" do
      described_class.perform_now(account)
      child = account.orders.find_by!(broker_order_id: "1004055538124")
      proposal = OrderProposal.create!(account: account, instrument: child.instrument, origin: :human, side: "BUY")
      child.update!(order_proposal: proposal, placed_via: :app)
      flat = fake.orders(hash, from: 1.day.ago).flat_map { |o| Schwab::Order.from(o).flatten }.map(&:raw)
      fake.enqueue(:orders) { flat }
      described_class.perform_now(account)
      expect(child.reload).to have_attributes(order_proposal: proposal, placed_via: "app")
      expect(child.parent_order).to be_present
    end

    it "leaves stop assignments untouched when the run fails" do
      described_class.perform_now(account)
      fake.enqueue(:orders) { raise Schwab::ServerError.new("down", status: 503) }
      described_class.perform_now(account)
      expect(SyncRun.last).to be_failed
      expect(account.positions.protected_by_stop.count).to eq(2)
    end

    it "audits an unrecoverable gap when the cursor is older than the lookback" do
      create(:sync_run, feed: "orders", account: account, window_to: 400.days.ago)
      described_class.perform_now(account)
      expect(SyncRun.last.gap_from).to be_within(2.seconds).of(400.days.ago)
      expect(AuditEvent.where(kind: "sync_gap_unrecoverable")).to exist
    end
  end

  describe Sync::ActivitiesJob do
    let!(:account) { create(:account, schwab_hash: hash, trading_enabled: true) }

    it "upserts every type, classifies kinds, links orders, and counts the sweep" do
      Sync::OrdersJob.perform_now(account)
      described_class.perform_now(account)
      expect(account.activities.pluck(:kind).sort).to eq(%w[ deposit dividend fill sweep ])
      expect(Activity.valid_for_journal.count).to eq(4)
      fill = account.activities.find_by!(kind: "fill")
      expect(fill.order.broker_order_id).to eq("1004055538123")
      expect(fill).to have_attributes(side: "BUY", quantity: 40, fees: BigDecimal("0.05"), status: "VALID")
      expect(SyncRun.last).to be_succeeded
      described_class.perform_now(account)
      expect(account.activities.count).to eq(4)
    end

    it "fails the run on a rejected type so the cursor does not advance, but keeps the rows that arrived" do
      fake.enqueue(:transactions) { raise Schwab::RequestError.new("bad window", status: 400) }
      described_class.perform_now(account)
      expect(SyncRun.last).to be_failed
      expect(SyncRun.last.unmapped_values["activity_types_rejected"].first).to start_with("TRADE")
      expect(account.activities.where(kind: "dividend")).to exist
      expect(SyncRun.last_window_to(:activities, account)).to be_nil
    end

    it "quarantines one malformed activity and keeps the rest of its type" do
      fake.enqueue(:transactions) { [ { "activityId" => 9 } ] + fake.transactions(hash, from: 1.day.ago, type: "TRADE") }
      described_class.perform_now(account)
      expect(account.activities.where(kind: "fill")).to exist
      expect(SyncRun.last).to be_partial
      expect(SyncRun.last.unmapped_values["activities_unmapped"].first).to include("time")
    end

    it "counts an unclassifiable activity as partial rather than a quiet success" do
      fake.enqueue(:transactions) { [ { "activityId" => 5, "type" => "SMA_ADJUSTMENT", "tradeDate" => "2026-08-14T00:00:00+0000", "netAmount" => 1 } ] }
      described_class.perform_now(account)
      expect(account.activities.find_by(broker_activity_id: "5")).to be_other
      expect(SyncRun.last).to be_partial
    end
  end
end
