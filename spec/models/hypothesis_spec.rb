require "rails_helper"

RSpec.describe Hypothesis do
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:account) { create(:account) }
  let(:breakout) { create(:setup, name: "Breakout") }

  around { |example| travel_to(Time.current.in_time_zone(MarketDay::ZONE).change(hour: 12)) { example.run } } # every proposal below is today's, after the holdout

  def write(**claim) = described_class.write!({ statement: "Breakouts on volume pay", rules: "close above the 20-day high on 1.5x volume", setup: breakout,
                                                min_sample: 10, holdout_from: MarketDay.today, expected_mean_r: 0.4 }.merge(claim), user: john)

  # A trade whose entry proposal named the hypothesis, proposed at the given time, closed with an R unless open.
  def evidence(hypothesis, r, proposed: Time.current, closed: Time.current, excluded: false, open: false)
    proposal = create(:order_proposal, account: account, status: "filled", setup: hypothesis.setup, hypothesis: hypothesis, created_at: proposed)
    create(:trade, account: account, instrument: proposal.instrument, order_proposal: proposal, status: open ? "open" : "closed", closed_at: (closed unless open),
                   realized_r: (r unless open), excluded_from_stats: excluded)
  end

  it "is written before the evidence, never edited, never backdated, with an audit row" do
    hypothesis = write
    expect(AuditEvent.where(kind: "hypothesis_created", subject: hypothesis).sole.data).to include("setup" => "Breakout", "min_sample" => 10)
    expect { write(holdout_from: MarketDay.today - 1) }.to raise_error(ActiveRecord::RecordInvalid, /cannot be before today/)
    expect { described_class.transaction(requires_new: true) { described_class.where(id: hypothesis).update_all(min_sample: 20) } }.to raise_error(ActiveRecord::StatementInvalid, /never edited: write a variant/)
    expect { described_class.transaction(requires_new: true) { described_class.where(id: hypothesis).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /never deleted/)
    variant = write(min_sample: 20, parent: hypothesis)
    expect(hypothesis.variants).to eq([ variant ])
    hypothesis.retire!(user: john, reason: "superseded by the variant") # a proposed hypothesis retires without ever joining the family
    expect(hypothesis.reload).to have_attributes(status: "retired", tested_at: nil)
  end

  it "fixes the sample in the order proposed, not closed, and waits until all of it has closed with an R" do
    hypothesis = write
    hypothesis.test!(user: john, reason: "enough breakouts on the watchlist")
    slow = evidence(hypothesis, nil, proposed: 3.hours.ago, open: true) # first proposed, still running
    9.times { |i| evidence(hypothesis, -1.0, proposed: 2.hours.ago + i.minutes) }
    evidence(hypothesis, 2.0) # the eleventh proposed: outside the sample however fast it closed
    create(:trade, account: account, status: "closed", closed_at: Time.current, realized_r: 3, setup: breakout) # the setup's, but never named
    expect(hypothesis.reload.sample).to include(slow)
    expect(hypothesis.sample.size).to eq(10)
    expect(hypothesis).not_to be_ready
    expect(hypothesis.verdict).to be_nil
    expect { hypothesis.decide!(decision: "rejected", user: john, reason: "x") }.to raise_error(ArgumentError, /9 of 10 trades closed with an R/)
  end

  it "judges the sample against a bar that counts the hypotheses tested when it completed, and freezes the verdict" do
    hypothesis = write
    hypothesis.test!(user: john, reason: "go")
    10.times { |i| evidence(hypothesis, 1.5 + (i % 3) * 0.1, proposed: 1.hour.ago + i.minutes, closed: 10.minutes.ago) }
    verdict = hypothesis.reload.verdict
    expect(verdict).to include("n" => 10, "tests" => 1, "bar" => 0.05, "clears" => true, "indicative" => true, "at_or_above_declared" => true)
    expect(verdict["p_value"]).to be < 0.01
    write(statement: "another").test!(user: john, reason: "and another") # tested after the sample completed: not in its family
    expect(Hypothesis.new(hypothesis.attributes).verdict).to include("tests" => 1) # and so not in the verdict, whenever it is decided
    hypothesis.decide!(decision: "accepted", user: john, reason: "it held")
    expect(hypothesis.reload).to have_attributes(status: "accepted", decided_by: john, decision_note: "it held")
    expect(hypothesis.evidence["r"].keys).to match_array(hypothesis.sample.map { it.id.to_s })
    expect { described_class.transaction(requires_new: true) { described_class.where(id: hypothesis).update_all(evidence: {}) } }.to raise_error(ActiveRecord::StatementInvalid, /frozen once made/)
    expect { described_class.transaction(requires_new: true) { described_class.where(id: hypothesis).update_all(status: "testing") } }.to raise_error(ActiveRecord::StatementInvalid, /cannot go from accepted to testing/)
    expect(AuditEvent.where(kind: "hypothesis_status_changed", subject: hypothesis).pluck(:data).map { it.values_at("from", "to") }).to eq([ %w[ proposed testing ], %w[ testing accepted ] ])
  end

  it "refuses to accept a verdict that does not clear, counts excluded trades, and keeps the verdict of a hypothesis retired when ready" do
    hypothesis = write
    hypothesis.test!(user: john, reason: "go")
    5.times { |i| evidence(hypothesis, 1.0, proposed: 1.hour.ago + i.minutes) }
    5.times { |i| evidence(hypothesis, -1.0, proposed: 30.minutes.ago + i.minutes, excluded: true) }
    expect(hypothesis.reload.verdict).to include("clears" => false, "mean_r" => 0.0)
    expect(hypothesis.verdict["excluded_trade_ids"].size).to eq(5)
    expect { hypothesis.decide!(decision: "accepted", user: john, reason: "hope") }.to raise_error(ArgumentError, /does not clear the bar/)
    hypothesis.retire!(user: john, reason: "moving on")
    expect(hypothesis.reload).to have_attributes(status: "retired", decision_note: "moving on")
    expect(hypothesis.evidence).to include("clears" => false, "n" => 10) # a failure is on record
    expect { write.retire!(user: john, reason: "") }.to raise_error(ArgumentError, /reason is required/)
  end

  it "keeps an evidence trade's stop the proposal's at review, so its R cannot be moved after the outcome" do
    hypothesis = write
    hypothesis.test!(user: john, reason: "go")
    trade = evidence(hypothesis, -1.0)
    trade.update!(planned_stop: 47)
    expect(trade.review(setup: breakout, planned_stop: "45", thesis: "t", user: john)).to be(false)
    expect(trade.errors[:planned_stop].first).to include("frozen while this trade is evidence for hypothesis ##{hypothesis.id}")
    expect(trade.review(setup: breakout, planned_stop: "47", thesis: "t", user: john)).to be(true)
  end
end
