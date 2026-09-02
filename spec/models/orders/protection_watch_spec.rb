require "rails_helper"

RSpec.describe Orders::ProtectionWatch do
  include ActiveJob::TestHelper

  let!(:user) { create(:user, email_address: "john@athayde.com") }
  let(:account) { create(:account) }
  let(:xyz) { create(:instrument, symbol: "XYZ") }

  def alerts = AuditEvent.where(kind: "unprotected_alert_sent")

  it "stays quiet for an unprotected position nobody expected to be protected" do
    create(:position, account: account, instrument: xyz, quantity: 10)
    expect { described_class.call(account) }.not_to have_enqueued_mail(AlertMailer, :unprotected_position)
    expect(alerts).to be_empty
  end

  it "alerts once a day for a position whose entry the app placed" do
    position = create(:position, account: account, instrument: xyz, quantity: 10)
    OrderProposal.create!(account: account, instrument: xyz, kind: :entry, origin: :human, side: :buy, status: "filled", quantity: 10, limit_price: 50)
    expect { described_class.call(account); described_class.call(account) }.to have_enqueued_mail(AlertMailer, :unprotected_position).with(position).once
    expect(alerts.where(subject: position).count).to eq(1)
    travel 25.hours
    expect { described_class.call(account) }.to have_enqueued_mail(AlertMailer, :unprotected_position).with(position).once
  end

  it "alerts when a stop died at the broker today, and the mail names the state" do
    position = create(:position, account: account, instrument: xyz, quantity: 5)
    create(:order, :working_stop, account: account, instrument: xyz, status: "CANCELED", closed_at: 1.hour.ago, broker_order_id: "gone-1")
    expect { described_class.call(account) }.to have_enqueued_mail(AlertMailer, :unprotected_position).with(position)
    mail = AlertMailer.unprotected_position(position)
    expect(mail.subject).to eq("Athayde Desk: XYZ is unprotected")
    expect(mail.text_part.body.to_s).to include("no stop")
  end
end
