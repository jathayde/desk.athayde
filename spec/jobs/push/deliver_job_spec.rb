require "rails_helper"

RSpec.describe Push::DeliverJob do
  it "never raises, so a push that did not land is not retried" do
    create(:device, user: create(:user), token: "t")
    Push::FakeApns.instance.enqueue { raise SocketError, "connection reset" }
    expect { described_class.perform_now(title: "t", body: "b", path: "/") }.not_to raise_error
  end
end
