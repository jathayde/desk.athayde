# Builds activities the way the sync writes them, so journal specs read as trade sequences.
module JournalHelpers
  # A fill as Schwab sends it (the net amount is the helper's arithmetic; the quantity, side, and fee rules
  # are the mapper's), written the way the sync writes it.
  def fill(account, instrument, side, qty, price, at:, fees: 0, order: nil, status: "VALID")
    net = side == "BUY" ? -(qty.to_d * price.to_d) - fees.to_d : (qty.to_d * price.to_d) - fees.to_d
    items = [ { "instrument" => { "assetType" => instrument.asset_type, "cusip" => instrument.cusip, "symbol" => instrument.symbol },
                "amount" => (side == "BUY" ? qty : -qty).to_d.to_s("F"), "price" => price.to_d.to_s("F"), "positionEffect" => side == "BUY" ? "OPENING" : "CLOSING" } ]
    items << { "instrument" => { "assetType" => "CURRENCY", "symbol" => "CURRENCY_USD" }, "amount" => (-fees.to_d).to_s("F"), "feeType" => "SEC_FEE" } if fees.to_d.nonzero?
    activity_from_raw(account, instrument, { "activityId" => SecureRandom.hex(5), "type" => "TRADE", "status" => status, "time" => at.utc.iso8601, "tradeDate" => at.utc.iso8601,
                                  "orderId" => order&.broker_order_id, "netAmount" => net.to_s("F"), "transferItems" => items }, order: order)
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
    activity_from_raw(account, instrument, { "activityId" => SecureRandom.hex(4), "type" => "RECEIVE_AND_DELIVER", "status" => "VALID", "tradeDate" => at.utc.iso8601, "netAmount" => cash,
                                  "transferItems" => [ { "instrument" => { "assetType" => instrument.asset_type, "cusip" => instrument.cusip, "symbol" => instrument.symbol }, "amount" => shares } ] })
  end

  def link!(account) = Journal::Linker.new(account).link_all!

  private
    # Whatever the sync would have written from this raw: the same assignment the job uses.
    def activity_from_raw(account, instrument, raw, order: nil)
      account.activities.new(instrument: instrument, order: order).assign_from(Schwab::Activity.from(raw)).tap(&:save!)
    end
end

RSpec.configure { |c| c.include JournalHelpers }
