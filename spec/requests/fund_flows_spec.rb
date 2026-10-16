require "rails_helper"

RSpec.describe "Fund flows and the Sunday allocation sections" do
  let!(:account) { create(:account, schwab_hash: Schwab::FakeClient::ACCOUNT_HASH) }
  let!(:token) { create(:schwab_token) }
  let(:john) { create(:user, email_address: "john@athayde.com", approver: true) }
  let(:whitney) { create(:user, email_address: "whitney@athayde.com") }

  it "takes the week's fund flow by hand, replaces it on a second entry, audits both, and keeps the second user out" do
    sign_in john
    post fund_flows_path, params: { as_of: "2026-10-12", amount: "-4.2", source: "" }
    expect(flash[:notice]).to eq("Fund flow for the week of Oct 12 saved.")
    post fund_flows_path, params: { as_of: "2026-10-14", amount: "-3.9", source: "ICI, revised" } # the Wednesday of the same week
    expect(FundFlow.sole).to have_attributes(amount: BigDecimal("-3.9"), source: "ICI, revised")
    expect(AuditEvent.where(kind: "fund_flow_changed").order(:id).last.data).to include("before" => { "amount" => "-4.2", "source" => "ICI weekly release, by hand" })
    post fund_flows_path, params: { as_of: (Date.current + 7).iso8601, amount: "1" }
    expect(flash[:alert]).to eq("As of is in the future")
    post fund_flows_path, params: { as_of: "2026-10-12", amount: "1e20" }
    expect(flash[:alert]).to include("Amount must be less than")
    get system_path
    expect(response.body).to include("$-3.9B, week of Oct 12 (ICI, revised)", "Save fund flow")
    delete session_path
    sign_in whitney
    post fund_flows_path, params: { as_of: "2026-10-19", amount: "1" }
    expect(FundFlow.count).to eq(1)
  end

  it "puts drift, cash drag, a diversifier moving with SPY, and the fund flow in the Sunday email from stored rows" do
    tlt = create(:instrument, symbol: "TLT")
    tlt.classify!(asset_class: nil, tags: %w[ diversifier ], user: john)
    RiskRule.create!(rule_type: "correlation_threshold", params: { "value" => "0.6", "window_days" => "60" })
    Correlation.create!(instrument: tlt, as_of: Date.new(2026, 10, 17), window_days: 60, value: BigDecimal("0.74"), last_close_on: Date.new(2026, 10, 16))
    AuditEvent.log("correlation_checked", actor: :system, data: { as_of: "2026-10-17", window_days: 60, computed: 1, skipped: { "GLD" => "history ends 2026-10-02" } })
    CashDragDiagnostic.create!(as_of: Date.new(2026, 10, 17), deployment_policy: DeploymentPolicy.create!(mode: "immediate"), cash_percent: BigDecimal("0.5"),
                               intended_cash_percent: BigDecimal("0.4"), weeks_in_cash: 4, threshold_weeks: 3, flagged: true)
    FundFlow.create!(as_of: Date.new(2026, 10, 12), amount: BigDecimal("-4.2"), source: "ICI", fetched_at: Time.current)
    run = AgentRun.create!(kind: :sunday_review, market_date: Date.new(2026, 10, 18), status: :succeeded, started_at: Time.current, finished_at: Time.current)
    text = BriefMailer.sunday_review(run).text_part.body.to_s
    expect(text).to include("Cash drag: 50.0% cash against 40.0% the targets leave, 4 weeks above the band (as of Oct 17): FLAGGED, past the 3-week threshold under a policy of deploy at once.",
                            "Diversifiers moving with SPY (above 0.6): TLT 0.74.", "Correlation with SPY, 60 days to Oct 16: TLT 0.74", "Not measured: GLD (history ends 2026-10-02)",
                            "Fund flow: $-4.2B, week of Oct 12 (ICI)")

    later = AgentRun.create!(kind: :sunday_review, market_date: Date.new(2026, 11, 1), status: :succeeded, started_at: Time.current, finished_at: Time.current)
    stale = BriefMailer.sunday_review(later).text_part.body.to_s # two weeks on, nothing new measured
    expect(stale).to include("(last checked Oct 17).", "Correlation with SPY, last measured: 60 days to Oct 16")
    expect(stale).not_to include("FLAGGED", "moving with SPY")
  end
end
