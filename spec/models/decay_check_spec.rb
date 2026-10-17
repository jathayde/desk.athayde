require "rails_helper"

RSpec.describe DecayCheck do
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:account) { create(:account) }
  let(:breakout) { create(:setup, name: "Breakout") }

  around { |example| travel_to(Time.current.in_time_zone(MarketDay::ZONE).change(hour: 12)) { example.run } }

  def evidence(hypothesis, r, at:)
    proposal = create(:order_proposal, account: account, status: "filled", setup: breakout, hypothesis: hypothesis, created_at: at)
    create(:trade, account: account, instrument: proposal.instrument, order_proposal: proposal, status: "closed", closed_at: at + 1.minute, realized_r: r)
  end

  let(:hypothesis) do
    Hypothesis.write!({ statement: "Breakouts pay", rules: "r", setup: breakout, min_sample: 10, holdout_from: MarketDay.today, expected_mean_r: 1.0 }, user: john).tap do |h|
      h.test!(user: john, reason: "go")
      10.times { |i| evidence(h, 1.5 + (i % 2) * 0.2, at: 3.hours.ago + i.minutes) }
      h.decide!(decision: "accepted", user: john, reason: "held")
    end
  end

  it "waits for twenty trades after the sample, marks a look below the declaration, and flags only the second in a row" do
    19.times { |i| evidence(hypothesis, -0.5, at: 2.hours.ago + i.minutes) }
    expect(described_class.record!(hypothesis, as_of: MarketDay.today)).to be_nil
    evidence(hypothesis, -0.6, at: 1.hour.ago)
    first = described_class.record!(hypothesis.reload, as_of: MarketDay.today)
    expect(first).to have_attributes(n: 20, below: true, flagged: false, expected_mean_r: 1.0, suggestion: nil)
    expect(AuditEvent.where(kind: "decay_check_recorded", subject: first).sole.data).to include("below" => true, "flagged" => false)
    expect(described_class.record!(hypothesis.reload, as_of: MarketDay.today + 7)).to be_nil # the same trades: no new look
    evidence(hypothesis, -0.4, at: 30.minutes.ago)
    second = described_class.record!(hypothesis.reload, as_of: MarketDay.today + 7)
    expect(second).to have_attributes(n: 21, below: true, flagged: true)
    expect(second.suggestion).to include("smaller max risk per trade for the Breakout setup")
    expect(Research::Digest.new.flagged_decay).to eq([ second ])
    hypothesis.retire!(user: john, reason: "it decayed")
    expect(Research::Digest.new.flagged_decay).to be_empty # never "decaying" once retired
  end

  it "never reads a trade the verdict's sample held" do
    20.times { |i| evidence(hypothesis, 1.2, at: 2.hours.ago + i.minutes) }
    expect(hypothesis.reload.since_sample.map(&:id)).not_to include(*hypothesis.evidence["r"].keys.map(&:to_i))
  end

  it "runs on Saturday for accepted hypotheses, and the entries after acceptance can still name one" do
    expect(Proposals.name_hypothesis(OrderProposal.new(kind: "entry"), hypothesis)).to eq(breakout)
    20.times { |i| evidence(hypothesis, 1.2, at: 2.hours.ago + i.minutes) }
    Research::DecayJob.perform_now(MarketDay.today)
    expect(hypothesis.decay_checks.sole).to have_attributes(n: 20, flagged: false)
  end
end
