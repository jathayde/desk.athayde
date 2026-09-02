require "rails_helper"

RSpec.describe Instrument do
  it "normalizes CUSIP and symbol, treating a blank CUSIP as none" do
    instrument = create(:instrument, cusip: " 037833100 ", symbol: " aapl ")
    expect(instrument).to have_attributes(cusip: "037833100", symbol: "AAPL")
    expect(create(:instrument, cusip: "").cusip).to be_nil
  end

  it "allows many instruments without a CUSIP or Schwab id" do
    create(:instrument, cusip: nil)
    expect { create(:instrument, cusip: nil) }.not_to raise_error
  end

  it "keeps CUSIP and Schwab id unique when present" do
    create(:instrument, cusip: "037833100", schwab_instrument_id: 7)
    expect { create(:instrument, cusip: "037833100") }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { create(:instrument, cusip: nil, schwab_instrument_id: 7) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "records ticker changes in UTC history without changing identity" do
    instrument = create(:instrument, cusip: "037833100", symbol: "OLD")
    instrument.rename!("NEW", at: Time.zone.parse("2026-09-01 10:00"))
    expect(instrument.reload).to have_attributes(symbol: "NEW", cusip: "037833100")
    expect(instrument.symbol_history).to eq([ { "symbol" => "OLD", "until" => "2026-09-01T14:00:00Z" } ])
  end

  it "cannot be its own predecessor" do
    instrument = create(:instrument)
    instrument.predecessor_instrument = instrument
    expect(instrument).not_to be_valid
  end
end

RSpec.describe Instrument, ".resolve by CUSIP alone" do
  it "names a CUSIP-only reference through Schwab rather than dropping it, and gives up only when Schwab cannot name it" do
    ref = Schwab::InstrumentRef.new(symbol: nil, cusip: "037833100", instrument_id: nil, asset_type: "EQUITY", description: nil)
    expect(Instrument.resolve(ref)).to have_attributes(cusip: "037833100", symbol: "XYZ")
    unknown = ref.with(cusip: "999999999")
    Schwab::FakeClient.instance.enqueue(:instrument_by_cusip) { [] }
    expect(Instrument.resolve(unknown)).to be_nil
    expect(Instrument.resolve(nil)).to be_nil
  end
end
