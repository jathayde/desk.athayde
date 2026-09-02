require "rails_helper"

RSpec.describe Sync::TickJob do
  let!(:trading) { create(:account, trading_enabled: true) }
  let!(:ira) { create(:account, trading_enabled: false, account_type: "ira") }

  it "enqueues every feed for every account on the first tick during the session, and only positions again after 5 minutes" do
    create(:schwab_token)
    travel_to Time.zone.parse("2026-09-08 10:00 EDT") do
      expect { described_class.perform_now }.to have_enqueued_job(Sync::PositionsJob).twice.and have_enqueued_job(Sync::OrdersJob).twice.and have_enqueued_job(Sync::ActivitiesJob).twice
      expect(MarketDay.count).to eq(8)
      [ trading, ira ].each { |a| %w[ positions orders activities ].each { |f| create(:sync_run, feed: f, account: a) } }
    end
    clear_enqueued_jobs
    travel_to Time.zone.parse("2026-09-08 10:05:01 EDT") do
      expect { described_class.perform_now }.to have_enqueued_job(Sync::OrdersJob).with(trading).once.and have_enqueued_job(Sync::ActivitiesJob).with(trading).once
      expect(Sync::PositionsJob).not_to have_been_enqueued
    end
  end

  it "uses the off-hours cadence outside the session, when only the day's snapshot is due" do
    travel_to Time.zone.parse("2026-09-08 22:00 EDT") do
      create(:schwab_token) # inside the travel: a token issued at the real clock would be seven days old here and unusable
      [ trading, ira ].each { |a| %w[ positions orders activities ].each { |f| create(:sync_run, feed: f, account: a, started_at: 30.minutes.ago) } }
      expect { described_class.perform_now }.to have_enqueued_job(Snapshots::DailyJob).with(trading, Date.new(2026, 9, 8)).once
      [ Sync::PositionsJob, Sync::OrdersJob, Sync::ActivitiesJob ].each { |job| expect(job).not_to have_been_enqueued }
    end
  end

  it "pauses without enqueueing when the token is unusable: one skipped row an hour, one audit an episode" do
    travel_to Time.zone.parse("2026-09-08 10:00 EDT") do
      expect { described_class.perform_now }.not_to have_enqueued_job
      described_class.perform_now
      expect(SyncRun.skipped_token.count).to eq(1)
      expect(AuditEvent.where(kind: "sync_paused_token_expired").count).to eq(1)
      expect(SystemSettings.instance.sync_paused_reason).to be_present
    end
    travel_to Time.zone.parse("2026-09-08 11:05 EDT") do
      described_class.perform_now
      expect(SyncRun.skipped_token.count).to eq(2)
    end
  end

  it "keeps ticking when the market-hours call fails" do
    create(:schwab_token)
    Schwab::FakeClient.instance.enqueue(:market_hours, sticky: true) { raise Schwab::TransportError.new("timeout") }
    travel_to Time.zone.parse("2026-09-08 10:00 EDT") do
      expect { described_class.perform_now }.to have_enqueued_job(Sync::OrdersJob).twice
      expect(MarketDay.for(MarketDay.today)).to be_fallback
    end
  end
end

RSpec.describe Sync::CatchUpJob do
  it "syncs accounts inline, then enqueues every feed for every account so the concurrency limits still apply" do
    create(:schwab_token)
    account = create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH, trading_enabled: true)
    %w[ positions orders activities ].each { |f| create(:sync_run, feed: f, account: account) }
    expect { described_class.perform_now }.to have_enqueued_job(Sync::PositionsJob).with(account)
      .and have_enqueued_job(Sync::OrdersJob).with(account, working_pass: true)
      .and have_enqueued_job(Sync::ActivitiesJob).with(account)
    expect(SyncRun.where(feed: "accounts", status: "succeeded")).to exist
  end
end
