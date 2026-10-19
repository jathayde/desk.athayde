require "rails_helper"

RSpec.describe Schwab::TokenHealthJob do
  let(:mail) { ActionMailer::Base.deliveries }
  let!(:user) { create(:user, email_address: "john@athayde.com", approver: true) }

  def run(at)
    travel_to(Time.zone.parse(at)) { described_class.perform_now }
  end

  def subjects = mail.map(&:subject)
  def subject_for(reason) = I18n.t("token_mailer.nag.subject.#{reason}")

  it "nags every run when there is no token, and when it is revoked or expired" do
    run("2026-09-09 08:00 EDT")
    token = create(:schwab_token, :revoked)
    run("2026-09-09 20:00 EDT")
    expect(subjects).to eq([ subject_for(:missing), subject_for(:revoked) ])
    expect(AuditEvent.where(kind: "token_nag_sent").order(:id).pluck(:reason)).to eq(%w[ missing revoked ])
    expect(AuditEvent.where(kind: "token_nag_sent").last.subject).to eq(token)
  end

  it "stays quiet all week after a Sunday re-auth, through the Sunday morning run inside the 24-hour window" do
    create(:schwab_token, issued_at: Time.zone.parse("2026-09-06 18:30 EDT"))
    %w[ 2026-09-07 2026-09-08 2026-09-09 2026-09-10 2026-09-11 2026-09-12 ].each do |day|
      run("#{day} 08:00 EDT")
      run("#{day} 20:00 EDT")
    end
    run("2026-09-13 08:00 EDT")
    expect(mail).to be_empty
    run("2026-09-13 20:00 EDT") # the ritual was skipped: the token is now dead and the nag says so
    expect(subjects).to eq([ subject_for(:expired) ])
  end

  it "warns once per token as it enters the 24-hour window when the Sunday email will not cover it" do
    create(:schwab_token, issued_at: Time.zone.parse("2026-09-03 10:00 EDT")) # Thursday; expires Thursday
    run("2026-09-09 08:00 EDT")
    run("2026-09-09 20:00 EDT")
    run("2026-09-10 08:00 EDT")
    expect(subjects).to eq([ subject_for(:expiring) ])
    expect(AuditEvent.where(kind: "token_nag_sent").pluck(:reason)).to eq([ "expiring" ])
  end

  it "escalates on Monday and Tuesday when the Sunday re-auth was missed" do
    create(:schwab_token, issued_at: Time.zone.parse("2026-09-02 10:00 EDT"))
    run("2026-09-07 08:00 EDT")
    run("2026-09-07 20:00 EDT")
    run("2026-09-08 08:00 EDT")
    expect(subjects).to eq([ subject_for(:missed_sunday) ] * 3)
    expect(mail.last.text_part.body.to_s).to include("before next Sunday's re-auth email")
  end

  it "treats a token issued before the Sunday email as missed, since it cannot reach the next one" do
    create(:schwab_token, issued_at: Time.zone.parse("2026-09-06 17:00 EDT"))
    run("2026-09-07 08:00 EDT")
    expect(subjects).to eq([ subject_for(:missed_sunday) ])
  end

  it "handles the fall-back DST week" do
    create(:schwab_token, issued_at: Time.zone.parse("2026-10-25 18:30 EDT"))
    run("2026-10-26 08:00 EDT")
    run("2026-10-27 08:00 EDT")
    expect(mail).to be_empty
  end

  it "addresses only the approver, never another reader even with notify on, with a re-auth link and never a token value" do
    create(:user, email_address: "whitney@athayde.com", notify: true)
    token = create(:schwab_token, :revoked)
    run("2026-09-09 08:00 EDT")
    expect(mail.last.to).to eq([ "john@athayde.com" ])
    body = mail.last.text_part.body.to_s + mail.last.html_part.body.to_s
    expect(body).to include("/schwab/authorize")
    expect(body).not_to include(token.access_token)
    expect(body).not_to include(token.refresh_token)
  end
end
