require "rails_helper"

RSpec.describe StopCollar::Calculator do
  let(:instrument) { create(:instrument, symbol: "XYZ", cusip: "037833100") }

  it "computes every method, takes tight and wide from the ATR and swing stops with the percent as the floor, and reports ok" do
    script_price_history(range: 1)
    collar = described_class.new(instrument, entry_price: 50, params: { "atr_k" => "1", "percent" => "8" }).call
    expect(collar).to be_ok
    expect(collar.methods.keys).to eq(%i[ atr swing percent chandelier ])
    expect(collar.floor).to eq(BigDecimal("46"))
    expect(collar.tight).to eq([ collar.methods[:atr], collar.methods[:swing] ].max)
    expect(collar.wide).to eq([ [ collar.methods[:atr], collar.methods[:swing] ].min, collar.floor ].max)
    expect(collar.tight).to be > collar.wide
    expect(collar.floor_dominates).to be(false)
    expect(collar.to_h["tight"]).to be_a(String) # jsonb-ready decimals
  end

  it "lets the floor be the whole collar, up to the entry, when it is tighter than every method" do
    script_price_history(range: 6) # wild bars: ATR and swing stops far below the 8% floor
    collar = described_class.new(instrument, entry_price: 50, params: { "percent" => "8" }).call
    expect(collar).to be_ok
    expect(collar.floor_dominates).to be(true)
    expect(collar.tight).to eq(collar.floor)
    expect(collar.wide).to eq(collar.floor)
  end

  it "refuses on too few candles, an old latest candle, a stale history, or a stale quote, naming the reason" do
    expect(described_class.new(instrument, entry_price: 50).call.refusal).to include("only 2 daily candles") # the shipped fixture
    Rails.cache.clear
    script_price_history(days: 40, ending: MarketDay.today - 10)
    expect(described_class.new(instrument, entry_price: 50).call.refusal).to include("more than 2 trading days old")
    Rails.cache.clear
    Agent::MarketData.quotes([ "XYZ" ])
    travel 3.minutes
    Schwab::FakeClient.instance.enqueue(:quotes, sticky: true) { raise Schwab::ServerError.new("down", status: 503) }
    script_price_history
    expect(described_class.new(instrument, entry_price: 50).call).to have_attributes(quality: :refused, refusal: "no fresh quote")
  end
end
