require "rails_helper"

RSpec.describe Order do
  it "knows which orders are working stops" do
    stop = create(:order, :working_stop)
    filled = create(:order, status: "FILLED", order_type: "LIMIT")
    expect(stop).to be_working.and be_stop
    expect(filled).not_to be_working
    expect(Order.working.stops).to contain_exactly(stop)
  end
end
