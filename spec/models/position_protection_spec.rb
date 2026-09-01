require "rails_helper"

RSpec.describe Position, "#assign_working_stop! and #protection" do
  let(:account) { create(:account) }
  let(:instrument) { create(:instrument) }
  let!(:position) { create(:position, account: account, instrument: instrument, quantity: 40, last_price: 53) }

  def stop(**attrs)
    create(:order, :working_stop, { account: account, instrument: instrument, quantity: 40, remaining_quantity: 40, entered_at: Time.current }.merge(attrs))
  end

  it "displays the newest live stop while coverage counts every live stop" do
    stop(entered_at: 2.days.ago, stop_price: 47, quantity: 20, remaining_quantity: 20)
    newer = stop(entered_at: 1.day.ago, stop_price: 48.9, quantity: 20, remaining_quantity: 20)
    position.assign_working_stop!
    expect(position.working_stop_order).to eq(newer)
    expect(position.protection).to eq(:protected)
  end

  it "reads two full-size live stops on one lot as oversized, since both would trigger" do
    stop(entered_at: 2.days.ago)
    stop(entered_at: 1.day.ago)
    position.assign_working_stop!
    expect(position.protection).to eq(:oversized)
  end

  it "prefers a live stop over a newer awaiting bracket child" do
    live = stop(entered_at: 2.days.ago)
    stop(entered_at: 1.hour.ago, status: "AWAITING_PARENT_ORDER", quantity: 20, remaining_quantity: 20)
    position.assign_working_stop!
    expect(position.working_stop_order).to eq(live)
  end

  it "follows a replacement chain to the terminal order" do
    replaced = stop(status: "REPLACED", entered_at: 2.days.ago)
    replacement = stop(entered_at: 1.day.ago, replaces_order: replaced)
    position.assign_working_stop!
    expect(position.working_stop_order).to eq(replacement)
  end

  it "treats a bracket child still awaiting its parent as not yet protecting anything" do
    stop(status: "AWAITING_PARENT_ORDER")
    position.assign_working_stop!
    expect(position.protection).to eq(:awaiting)
    expect(position).to be_unprotected
  end

  it "sums live stops so a scaled-in position covered by two stops reads as protected" do
    stop(quantity: 20, remaining_quantity: 20, entered_at: 2.days.ago)
    stop(quantity: 20, remaining_quantity: 20, entered_at: 1.day.ago)
    position.assign_working_stop!
    expect(position.covered_quantity).to eq(40)
    expect(position.protection).to eq(:protected)
  end

  it "reports partial, oversized, and trailing-unknown states as not protected" do
    partial = stop(quantity: 20, remaining_quantity: 20)
    position.update!(working_stop_order: partial)
    expect(position.protection).to eq(:partial)
    expect(position).to be_unprotected
    position.update!(working_stop_order: stop(quantity: 60, remaining_quantity: 60))
    expect(position.protection).to eq(:oversized)
    position.update!(working_stop_order: create(:order, :trailing_stop, account: account, instrument: instrument, quantity: 40, remaining_quantity: 40))
    expect(position.protection).to eq(:trailing_unknown)
    expect(position.open_risk).to be_nil
  end

  it "clears the stop when nothing working remains" do
    filled = stop(status: "FILLED")
    position.update!(working_stop_order: filled)
    position.assign_working_stop!
    expect(position.working_stop_order).to be_nil
    expect(position.protection).to eq(:unprotected)
  end
end
