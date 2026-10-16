require "rails_helper"

RSpec.describe Instrument, "#classify!" do
  let(:john) { create(:user, approver: true) }
  let(:instrument) { create(:instrument, symbol: "TQQQ") }

  it "writes the class and each tag change as its own audit row, and nothing for an unchanged save" do
    instrument.classify!(asset_class: " US Equity ", tags: [ "leveraged", "", "amplified" ], user: john)
    expect(instrument.reload).to have_attributes(asset_class: "us equity", tag_names: %w[ amplified leveraged ])
    instrument.classify!(asset_class: "us equity", tags: %w[ leveraged ], user: john)
    instrument.classify!(asset_class: "us equity", tags: %w[ leveraged ], user: john)
    expect(instrument.reload.tag_names).to eq(%w[ leveraged ])
    expect(AuditEvent.where(kind: "instrument_classified").sole.data).to eq("symbol" => "TQQQ", "before" => nil, "after" => "us equity")
    expect(AuditEvent.where(kind: "instrument_tagged").order(:id).map { |e| e.data.values_at("tag", "tagged") }).to eq([ [ "amplified", true ], [ "leveraged", true ], [ "amplified", false ] ])
    expect { instrument.classify!(asset_class: nil, tags: %w[ vibes ], user: john) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(instrument.reload).to have_attributes(asset_class: "us equity", tag_names: %w[ leveraged ]) # the refused tag rolled the class change back too
    expect(AuditEvent.where(kind: "instrument_classified").count).to eq(1) # and its audit row
  end
end
