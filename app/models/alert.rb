# The one place an alert leaves the desk (docs/phase-2-plan.md §9, §10): one sentence per event, sent as the
# email's subject and as the push's title with a line of body and the path the shell opens. Callers invoke
# these after the state they report is committed.
module Alert
  BODY_LIMIT = 180 # an agent's thesis can run to paragraphs; APNs refuses a payload past 4 KB

  def self.new_proposal(proposal)
    announce("#{proposal.label} #{proposal.status_label}", proposal.thesis.presence&.truncate(BODY_LIMIT) || "Open the proposal to decide.", routes.proposal_path(proposal)) do |subject|
      AlertMailer.new_proposal(proposal, subject: subject)
    end
  end

  def self.thesis_review(review)
    announce(review.alert_subject, review.alert_body, routes.thesis_review_path(review)) do |subject|
      AlertMailer.thesis_review(review, subject: subject)
    end
  end

  # New cash the desk gave up placing: it stays cash until the operator acts.
  def self.cash_left(inflow, amount)
    announce("#{ActiveSupport::NumberHelper.number_to_currency(amount)} of #{inflow.label} left as cash", "The deployment could not place it. Open allocation to decide.", routes.allocation_targets_path) do |subject|
      AlertMailer.cash_left(inflow, amount, subject: subject)
    end
  end

  def self.fill_or_cancel(proposal)
    announce("#{proposal.label} #{proposal.status}", "At Schwab. Open the proposal for the order.", routes.proposal_path(proposal)) do |subject|
      AlertMailer.fill_or_cancel(proposal, subject: subject)
    end
  end

  def self.submission_unknown(proposal)
    announce("a submission on #{proposal.instrument.symbol} is unresolved", "Schwab gave no answer. Check Schwab before doing anything else on #{proposal.instrument.symbol}.", routes.proposal_path(proposal)) do |subject|
      AlertMailer.submission_unknown(proposal, subject: subject)
    end
  end

  def self.late_submission(proposal)
    announce("#{proposal.label} is working at Schwab after all", "Schwab answered late. Check for a duplicate order.", routes.proposal_path(proposal)) do |subject|
      AlertMailer.late_submission(proposal, subject: subject)
    end
  end

  def self.halt_tripped(rule:, reason:, resets_at:)
    announce("entries halted by #{rule.humanize.downcase}", "#{reason}. Exits stay available.", routes.system_path) do |subject|
      AlertMailer.halt_tripped(rule: rule, reason: reason, resets_at: resets_at, subject: subject)
    end
  end

  def self.unprotected_position(position)
    announce("#{position.instrument.symbol} is unprotected", "No working stop. Place one at Schwab.", routes.root_path) do |subject|
      AlertMailer.unprotected_position(position, subject: subject)
    end
  end

  # The mail carries "Athayde Desk: #{sentence}"; the push carries the sentence alone, capitalised as a title.
  def self.announce(sentence, body, path)
    yield(sentence).deliver_later
    Push::DeliverJob.perform_later(title: sentence.upcase_first, body: body, path: path)
  end

  def self.routes = Rails.application.routes.url_helpers
  private_class_method :announce, :routes
end
