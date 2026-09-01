require "rails_helper"

RSpec.describe Schwab::Order do
  let(:orders) { schwab_fixture("orders").map { |o| described_class.from(o) } }

  it "flattens nested bracket children and replacements with lineage" do
    flat = orders.flat_map(&:flatten)
    expect(flat.map(&:order_id)).to eq(%w[ 1004055538123 1004055538124 1004055538200 1004055538201 ])
    child = flat[1]
    expect(child).to have_attributes(parent_order_id: "1004055538123", replaces_order_id: nil, order_type: "STOP", stop_price: BigDecimal("48.9"), side: "SELL")
    expect(child).to be_working.and be_stop
    replacement = flat[3]
    expect(replacement).to have_attributes(replaces_order_id: "1004055538200", parent_order_id: nil, stop_price: BigDecimal("86.5"))
  end

  it "keeps the parent when a bracket child is replaced" do
    raw = { "orderId" => 1, "childOrderStrategies" => [ { "orderId" => 2, "replacingOrderCollection" => [ { "orderId" => 3 } ] } ] }
    flat = described_class.from(raw).flatten
    expect(flat.last).to have_attributes(order_id: "3", parent_order_id: "1", replaces_order_id: "2")
  end

  it "maps the parent's fields and times" do
    parent = orders.first
    expect(parent).to have_attributes(status: "FILLED", side: "BUY", quantity: 40, filled_quantity: 40, price: BigDecimal("51.2"),
                                      tax_lot_method: "FIFO", duration: "GOOD_TILL_CANCEL", session: "NORMAL")
    expect(parent.entered_at).to eq(Time.utc(2026, 8, 14, 13, 31, 2))
    expect(parent.instrument.cusip).to eq("037833100")
  end

  it "passes unknown enum values through and treats a leg-less strategy as a container" do
    order = described_class.from({ "orderId" => 1, "status" => "SOMETHING_NEW", "orderType" => "WEIRD", "orderStrategyType" => "OCO" })
    expect(order.status).to eq("SOMETHING_NEW")
    expect(order).not_to be_working
    expect(order).to be_container
    expect(order.side).to be_nil
  end

  it "requires an orderId and a parseable time" do
    expect { described_class.from({}) }.to raise_error(Schwab::MappingError)
    expect { described_class.from({ "orderId" => 1, "enteredTime" => "yesterday" }) }.to raise_error(Schwab::MappingError)
  end
end
