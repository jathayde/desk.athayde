# Builds activities the way the sync writes them, so journal specs read as trade sequences.
module JournalHelpers
  def fill(account, instrument, side, qty, price, at:, fees: 0, order: nil, status: "VALID")
    signed = side == "BUY" ? -(qty * price) - fees : (qty * price) - fees
    create(:activity, account: account, instrument: instrument, kind: "fill", side: side, quantity: qty, price: price, fees: fees,
                      net_amount: signed, executed_at: at, trade_date: at.to_date, status: status, order: order, broker_order_id: order&.broker_order_id)
  end

  def income(account, instrument, amount, at:, kind: "dividend")
    create(:activity, account: account, instrument: instrument, kind: kind, side: nil, quantity: nil, price: nil, net_amount: amount,
                      executed_at: at, trade_date: at.to_date, status: "VALID")
  end

  # A cash flow as Schwab might send it: the magnitude, signed by kind unless a raw sign is forced.
  def flow(account, kind, magnitude, on:, sign: nil)
    amount = sign ? magnitude.abs * sign : (kind == "withdrawal" ? -magnitude.abs : magnitude.abs)
    create(:activity, account: account, instrument: nil, kind: kind, side: nil, quantity: nil, price: nil, net_amount: amount,
                      executed_at: on.to_time, trade_date: on, status: "VALID")
  end

  # A share delivery as the sync stores it from a RECEIVE_AND_DELIVER: quantity from the security item, direction in raw.
  def delivery(account, instrument, shares, at:, cash: 0)
    raw = { "activityId" => SecureRandom.hex(4), "type" => "RECEIVE_AND_DELIVER", "tradeDate" => at.utc.iso8601, "netAmount" => cash,
            "transferItems" => [ { "instrument" => { "assetType" => instrument.asset_type, "cusip" => instrument.cusip, "symbol" => instrument.symbol }, "amount" => shares } ] }
    mapped = Schwab::Activity.from(raw)
    create(:activity, account: account, instrument: instrument, kind: mapped.kind, quantity: mapped.quantity, price: nil, side: nil, net_amount: cash,
                      executed_at: at, trade_date: at.to_date, status: "VALID", raw: raw)
  end

  def link!(account) = Journal::Linker.new(account).link_all!
end

RSpec.configure { |c| c.include JournalHelpers }
