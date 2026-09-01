require "rails_helper"

RSpec.describe SyncRun do
  let(:account) { create(:account) }

  describe ".record" do
    it "succeeds, stamps the window, and counts touched records" do
      run = SyncRun.record(:orders, account: account, window_from: 1.day.ago, window_to: Time.current) { |r| r.touched(3) }
      expect(run).to be_succeeded
      expect(run).to have_attributes(records_touched: 3, account: account)
      expect(run.finished_at).to be_present
    end

    it "finishes partial when records were quarantined or the block says so" do
      quarantined = SyncRun.record(:orders, account: account) { |r| r.quarantine(:orders_unmapped, "no orderId") }
      expect(quarantined).to be_partial
      expect(quarantined.unmapped_values).to eq("orders_unmapped" => [ "no orderId" ])
      expect(SyncRun.record(:orders, account: account) { :partial }).to be_partial
    end

    it "records any other exception as failed and re-raises it so the queue sees it" do
      expect { SyncRun.record(:orders) { raise ActiveRecord::RecordNotUnique, "dup" } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(SyncRun.last).to be_failed
      expect(SyncRun.last.error).to include("RecordNotUnique")
    end

    it "turns token loss into skipped_token and other Schwab failures into failed, without raising" do
      expect(SyncRun.record(:orders) { raise Schwab::NoUsableToken, "none" }).to be_skipped_token
      expect(SyncRun.record(:orders) { raise Schwab::ReauthRequired.new("dead", status: 400) }).to be_skipped_token
      failed = SyncRun.record(:orders) { raise Schwab::ServerError.new("503", status: 503) }
      expect(failed).to be_failed
      expect(failed.error).to eq("503")
    end
  end

  describe "cursors and due checks" do
    it "advances the cursor on succeeded and partial runs only" do
      create(:sync_run, feed: "orders", account: account, status: "succeeded", window_to: 2.days.ago)
      create(:sync_run, feed: "orders", account: account, status: "partial", window_to: 1.day.ago)
      create(:sync_run, feed: "orders", account: account, status: "failed", window_to: 1.hour.ago)
      expect(SyncRun.last_window_to(:orders, account)).to be_within(1.second).of(1.day.ago)
      expect(SyncRun.last_window_to(:orders, create(:account))).to be_nil
    end

    it "ignores a running row older than the stale bound, so a crashed worker cannot freeze a feed" do
      create(:sync_run, feed: "orders", account: account, status: "running", finished_at: nil, started_at: 11.minutes.ago)
      expect(SyncRun.due?(:orders, account, every: 5.minutes)).to be(true)
    end

    it "is due when nothing ran, not while a run is in progress, and again after the interval minus slack" do
      expect(SyncRun.due?(:orders, account, every: 5.minutes)).to be(true)
      run = create(:sync_run, feed: "orders", account: account, status: "running", finished_at: nil)
      expect(SyncRun.due?(:orders, account, every: 5.minutes)).to be(false)
      run.finish!(:succeeded)
      expect(SyncRun.due?(:orders, account, every: 5.minutes)).to be(false)
      travel 4.minutes + 1.second
      expect(SyncRun.due?(:orders, account, every: 5.minutes)).to be(true)
    end
  end
end
