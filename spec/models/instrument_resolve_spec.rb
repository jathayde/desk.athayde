require "rails_helper"

RSpec.describe Instrument, ".resolve" do
  def ref(symbol:, cusip: nil, instrument_id: nil, asset_type: "EQUITY")
    Schwab::InstrumentRef.new(symbol: symbol, cusip: cusip, instrument_id: instrument_id, asset_type: asset_type, description: nil)
  end

  it "matches by CUSIP first and renames on a ticker change" do
    old = create(:instrument, cusip: "037833100", symbol: "OLD")
    expect(Instrument.resolve(ref(symbol: "NEW", cusip: "037833100"))).to eq(old)
    expect(old.reload.symbol).to eq("NEW")
    expect(old.symbol_history.first["symbol"]).to eq("OLD")
  end

  it "matches by Schwab id and backfills a missing CUSIP without overwriting a differing one" do
    row = create(:instrument, cusip: nil, schwab_instrument_id: 77, symbol: "SWVXX", asset_type: "CASH_EQUIVALENT")
    expect(Instrument.resolve(ref(symbol: "SWVXX", cusip: "808515605", instrument_id: 77, asset_type: "CASH_EQUIVALENT"))).to eq(row)
    expect(row.reload.cusip).to eq("808515605")
    expect(Instrument.resolve(ref(symbol: "SWVXX", cusip: "999999999", instrument_id: 77, asset_type: "CASH_EQUIVALENT")).cusip).to eq("808515605")
  end

  it "matches by symbol only among rows with no CUSIP, so a reused ticker cannot bind to the old company" do
    old = create(:instrument, cusip: "111111111", symbol: "ABC")
    resolved = Instrument.resolve(ref(symbol: "ABC", cusip: "222222222"))
    expect(resolved).not_to eq(old)
    expect(resolved.cusip).to eq("222222222")
    provisional = create(:instrument, cusip: nil, symbol: "XYZQ", asset_type: "EQUITY")
    expect(Instrument.resolve(ref(symbol: "XYZQ"))).to eq(provisional)
  end

  it "looks the CUSIP up by symbol before creating a provisional row, and audits only the provisional case" do
    resolved = Instrument.resolve(ref(symbol: "XYZ"))
    expect(resolved.cusip).to eq("037833100")
    expect(AuditEvent.where(kind: "instrument_identity_fallback")).not_to exist
    provisional = Instrument.resolve(ref(symbol: "NOPE", asset_type: "CASH_EQUIVALENT"))
    expect(provisional.cusip).to be_nil
    expect(AuditEvent.where(kind: "instrument_identity_fallback").count).to eq(1)
    Instrument.resolve(ref(symbol: "NOPE", asset_type: "CASH_EQUIVALENT"))
    expect(AuditEvent.where(kind: "instrument_identity_fallback").count).to eq(1)
  end

  it "reuses the existing row when the symbol lookup returns a CUSIP that is already known, instead of looping" do
    existing = create(:instrument, cusip: "808515605", symbol: "SWVXX", asset_type: "CASH_EQUIVALENT")
    expect(Instrument.resolve(ref(symbol: "SWVXX", asset_type: "CASH_EQUIVALENT"))).to eq(existing)
    expect(Instrument.count).to eq(1)
  end

  it "does not steal an identifier another row already owns" do
    owner = create(:instrument, cusip: "037833100", symbol: "OLD")
    other = create(:instrument, cusip: nil, symbol: "XYZ", asset_type: "EQUITY")
    other.absorb(ref(symbol: "XYZ", cusip: "037833100"))
    expect(other.reload.cusip).to be_nil
    expect(owner.reload.cusip).to eq("037833100")
  end

  it "gives up with a MappingError after one collision retry" do
    allow(Instrument).to receive(:create_from).and_raise(ActiveRecord::RecordNotUnique.new("dup"))
    expect { Instrument.resolve(ref(symbol: "LOOP", asset_type: "EQUITY")) }.to raise_error(Schwab::MappingError, /colliding/)
  end

  it "survives a lookup failure and a duplicate race" do
    Schwab::FakeClient.instance.enqueue(:instrument_by_symbol) { raise Schwab::ServerError.new("down", status: 503) }
    expect(Instrument.resolve(ref(symbol: "QQQQ")).cusip).to be_nil
    allow(Instrument).to receive(:create_from).and_wrap_original do |m, *args|
      Instrument.create!(cusip: "555555555", symbol: "RACE", asset_type: "EQUITY") unless Instrument.exists?(cusip: "555555555")
      m.call(*args)
    end
    expect(Instrument.resolve(ref(symbol: "RACE", cusip: "555555555")).cusip).to eq("555555555")
    expect(Instrument.where(cusip: "555555555").count).to eq(1)
  end
end
