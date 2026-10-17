require "rails_helper"

RSpec.describe Agent::SkepticNote do
  it "reads the risk line loosely, never leaves it in the note, and names a word off the list other" do
    expect(described_class.parse("No volume.\n**Risk: Timing.**\n\n")).to have_attributes(note: "No volume.", risk: "timing")
    expect(described_class.parse("No volume.\nRisk: vibes")).to have_attributes(note: "No volume.", risk: "other")
    expect(described_class.parse("No volume, and no risk line.")).to have_attributes(note: "No volume, and no risk line.", risk: "other")
    expect(described_class.parse("Risk: cost").note).to eq("")
    expect(described_class.parse("x " * 1_500).note).to end_with("[cut at 2000 characters]")
  end
end
