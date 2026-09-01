require "rails_helper"

RSpec.describe "Journal and snapshot hooks from sync" do
  let!(:token) { create(:schwab_token) }
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH, trading_enabled: true) }

  it "bootstraps trades after a complete positions sync and links fills after activities" do
    expect { Sync::PositionsJob.perform_now(account) }.to have_enqueued_job(Journal::BootstrapJob).with(account)
    Journal::BootstrapJob.perform_now(account)
    expect(account.trades.open.count).to eq(3)
    expect(account.trades.all?(&:bootstrapped?)).to be(true)
    expect { Sync::ActivitiesJob.perform_now(account) }.to have_enqueued_job(Journal::LinkFillsJob).with(account).and have_enqueued_job(Snapshots::RebuildJob)
    Journal::LinkFillsJob.perform_now(account)
    xyz = account.trades.joins(:instrument).find_by!(instruments: { symbol: "XYZ" })
    expect(xyz.trade_legs.where(activity_id: nil)).not_to exist # the 40-share fill replaced the plug
    expect(xyz.quantity).to eq(40)
    expect(xyz.trade_legs.kind_income.count).to eq(1)
  end

  it "does not hook journaling for a read-only account" do
    account.update!(trading_enabled: false)
    expect { Sync::PositionsJob.perform_now(account) }.not_to have_enqueued_job(Journal::BootstrapJob)
  end

  it "rechains today only when its equity moved" do
    MarketDay.for(Date.new(2026, 9, 8))
    travel_to Time.zone.parse("2026-09-08 16:40 EDT") do
      create(:snapshot, account: account, as_of: Date.new(2026, 9, 8), equity: BigDecimal("6508.55"))
      expect { Sync::PositionsJob.perform_now(account) }.not_to have_enqueued_job(Snapshots::RebuildJob)
      account.snapshots.sole.update!(equity: 1)
      expect { Sync::PositionsJob.perform_now(account) }.to have_enqueued_job(Snapshots::RebuildJob).with(account, from: Date.new(2026, 9, 8))
    end
  end

  it "schedules the daily snapshot once, after the close, after a positions sync" do
    MarketDay.for(Date.new(2026, 9, 8))
    travel_to Time.zone.parse("2026-09-08 16:25 EDT") do
      create(:sync_run, feed: "positions", account: account, status: "succeeded", started_at: 2.minutes.ago)
      %w[ orders activities ].each { |f| create(:sync_run, feed: f, account: account, started_at: 1.minute.ago) }
      expect { Sync::TickJob.perform_now }.to have_enqueued_job(Snapshots::DailyJob).with(account, Date.new(2026, 9, 8)).once
      create(:snapshot, account: account, as_of: Date.new(2026, 9, 8))
      expect { Sync::TickJob.perform_now }.not_to have_enqueued_job(Snapshots::DailyJob)
    end
  end
end
