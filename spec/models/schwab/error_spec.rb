require "rails_helper"

RSpec.describe Schwab::Error do
  def response(code, body = "")
    Net::HTTPResponse.new("1.1", code.to_s, "x").tap { |r| r.instance_variable_set(:@body, body); r.instance_variable_set(:@read, true) }
  end

  it "maps statuses to classes and keeps the request id" do
    body = '{"errors":[{"id":"abc-123","status":"400","title":"Bad","detail":"startDate too early"}]}'
    expect(described_class.for_response(response(400, body), attempts: 1, idempotent: true)).to be_a(Schwab::RequestError).and have_attributes(request_id: "abc-123", message: /startDate too early/)
    expect(described_class.for_response(response(401), attempts: 1, idempotent: true)).to be_a(Schwab::AuthError)
    limited = described_class.for_response(response(429).tap { |r| r["Retry-After"] = "12" }, attempts: 3, idempotent: true)
    expect(limited).to be_a(Schwab::RateLimited).and have_attributes(attempts: 3, retry_after: 12)
    expect(described_class.for_response(response(418), attempts: 1, idempotent: true)).to be_a(Schwab::RequestError)
    expect(described_class.for_response(response(503), attempts: 1, idempotent: true)).to be_a(Schwab::ServerError)
    expect(described_class.for_response(response(503), attempts: 1, idempotent: false)).to be_a(Schwab::UnknownOutcome)
  end

  it "scrubs account numbers out of the stored body" do
    error = described_class.for_response(response(400, '{"accountNumber":"12345678"}'), attempts: 1, idempotent: true)
    expect(error.body).not_to include("12345678")
  end
end
