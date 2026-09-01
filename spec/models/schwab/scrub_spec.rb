require "rails_helper"

RSpec.describe Schwab::Scrub do
  it "drops plaintext account numbers and user blocks anywhere in a body" do
    raw = { "securitiesAccount" => { "accountNumber" => "12345678", "positions" => [ { "accountNumber" => 1 } ] },
            "user" => { "firstName" => "John" }, "orderId" => 5 }
    expect(described_class.json(raw)).to eq("securitiesAccount" => { "accountNumber" => nil, "positions" => [ { "accountNumber" => nil } ] },
                                            "user" => nil, "orderId" => 5)
  end

  it "scrubs JSON text and passes non-JSON through" do
    expect(described_class.body('{"accountNumber":"1","x":2}')).to eq('{"accountNumber":null,"x":2}')
    expect(described_class.body("<html>gateway 12345678 error</html>")).to eq("<html>gateway <REDACTED> error</html>")
  end

  it "replaces account hashes in paths for logs" do
    expect(described_class.path("/trader/v1/accounts/#{Schwab::FakeClient::ACCOUNT_HASH}/orders")).to eq("/trader/v1/accounts/{hash}/orders")
  end
end
