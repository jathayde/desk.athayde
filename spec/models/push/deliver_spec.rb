require "rails_helper"

RSpec.describe Push::Deliver do
  let(:apns) { Push::FakeApns.instance }
  let!(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let!(:whitney) { create(:user, email_address: "whitney@athayde.com") }

  it "pushes the sentence to every registered device, oldest first, with the path the shell opens" do
    create(:device, user: john, token: "john-1")
    create(:device, user: whitney, token: "whitney-1")
    expect(described_class.call(title: "BUY 33 XYZ waiting for you", body: "base breakout", path: "/proposals/1")).to eq(2)
    expect(apns.pushed.map(&:token)).to eq(%w[ john-1 whitney-1 ])
    notification = apns.pushed.first
    expect(notification.alert).to eq(title: "BUY 33 XYZ waiting for you", body: "base breakout")
    expect(notification.custom_payload).to eq(path: "/proposals/1")
    expect(notification.topic).to eq("com.meticulous.athayde-desk")
    expect(notification.sound).to eq("default")
  end

  it "removes a device on Apple's permanent answers, audited, and keeps it on everything else" do
    phone = create(:device, user: john, token: "john-1")
    dead = create(:device, user: whitney, token: "whitney-1")
    apns.enqueue(status: "200")
    apns.enqueue(status: "410", reason: "Unregistered")
    expect(described_class.call(title: "t", body: "b", path: "/")).to eq(1)
    expect(Device.where(id: dead.id)).not_to exist
    expect(Device.where(id: phone.id)).to exist
    expect(AuditEvent.where(kind: "device_removed").sole).to have_attributes(user: whitney, reason: "Unregistered")
    apns.enqueue(status: "429", reason: "TooManyRequests")
    apns.enqueue(status: "400", reason: "DeviceTokenNotForTopic")
    apns.enqueue { nil }
    apns.enqueue { raise SocketError, "connection reset" }
    4.times { expect(described_class.call(title: "t", body: "b", path: "/")).to eq(0) }
    expect(Device.where(id: phone.id)).to exist
    expect(AuditEvent.where(kind: "device_removed").count).to eq(1)
    apns.enqueue(status: "400", reason: "BadDeviceToken")
    described_class.call(title: "t", body: "b", path: "/")
    expect(Device.count).to eq(0)
  end

  it "opens no connection when nobody has a device, and skips the phone of a user who is not notified" do
    expect(described_class.call(title: "t", body: "b", path: "/")).to eq(0)
    expect(apns.pushed).to be_empty
    whitney.update!(notify: false)
    create(:device, user: whitney, token: "whitney-1")
    expect(described_class.call(title: "t", body: "b", path: "/")).to eq(0)
    expect(apns.pushed).to be_empty
  end

  it "sends nothing on a real desk whose credentials carry no APNs key, and takes the topic from the credentials" do
    create(:device, user: john, token: "john-1")
    allow(Push).to receive(:fake?).and_return(false)
    allow(Rails.application.credentials).to receive(:apns).and_return(nil)
    expect(Push).not_to be_configured
    expect(described_class.call(title: "t", body: "b", path: "/")).to eq(0)
    expect(apns.pushed).to be_empty
    allow(Rails.application.credentials).to receive(:apns).and_return({ key: "-----BEGIN PRIVATE KEY-----", key_id: "K", team_id: "T", bundle_id: "com.meticulous.desk" })
    expect(Push).to be_configured
    expect(Push.topic).to eq("com.meticulous.desk")
  end

  it "refuses, in the fake, a payload past Apple's limit, so a runaway body fails here and not in production" do
    create(:device, user: john, token: "john-1")
    expect(described_class.call(title: "t", body: "x" * 5000, path: "/")).to eq(0)
    expect(apns.pushed).to be_empty
  end
end
