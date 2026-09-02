# Approve is the submission. Transaction one: lock the proposal, check the approver and the gates, re-evaluate
# over the frozen sizing and refuse anything that changed, move to submitting with the attempt row. Then the
# branch: shadow audits what would have been sent; the real call arrives in step 4 and is refused until then.
# A refusal rolls transaction one back, leaves the row as it was, and is audited outside it.
class Submission::Submit
  # A blocking re-evaluation carries its report out of the transaction, so the halt it asked for is engaged after the rollback.
  class Blocked < StandardError
    attr_reader :report
    def initialize(report) = (@report = report; super("blocked"))
  end

  def self.call(proposal, **) = new(proposal, **).call

  def initialize(proposal, user:, acknowledged: [], override_reason: nil)
    @proposal, @user, @acknowledged, @override_reason = proposal, user, Array(acknowledged).map(&:to_s), override_reason.presence
  end

  def call
    raise Submission::Refused, "real submission is not built yet; shadow mode must stay on" unless SystemSettings.instance.shadow_mode?
    attempt = OrderProposal.transaction { first_transaction }
    @proposal.record_shadow!(attempt)
  rescue Blocked => e
    Guardrails.engage_halts!(e.report)
    refuse "the desk changed: #{e.report.results.select(&:block?).map { |r| r.rule_type.humanize.downcase }.to_sentence} now block; re-propose"
  rescue Submission::Refused => e
    refuse e.message
  end

  private
    def first_transaction
      @proposal.lock!
      raise Submission::Refused, "only the approver can approve" unless @user&.approver?
      raise Submission::Refused, "proposal #{@proposal.id} is #{@proposal.status}, not waiting for a decision" unless @proposal.approvable?
      settings = SystemSettings.instance
      raise Submission::Refused, "halted: #{settings.manual_halt_reason}" if settings.manual_halt?
      raise Submission::Refused, "entries are halted by #{settings.rule_halt_rule}" if @proposal.kind_entry? && !settings.entries_allowed?
      report = Guardrails::Evaluator.new(@proposal).call
      raise Blocked.new(report) if report.blocked?
      raise Submission::Refused, "the desk changed: sizing would differ; re-propose" if sizing_changed?
      new_warnings = report.warnings - @proposal.warnings
      raise Submission::Refused, "the desk changed: #{new_warnings.map { |r| r.humanize.downcase }.to_sentence} now warn; re-propose" if new_warnings.any?
      unacknowledged = report.warnings - @acknowledged
      raise Submission::Refused, "acknowledge #{unacknowledged.map { |r| r.humanize.downcase }.to_sentence} first" if unacknowledged.any?
      raise Submission::Refused, "the stop is outside the collar; an override reason is required" if report.needs_override? && @override_reason.nil?
      @proposal.update!(guardrail_results: report.to_h, evaluated_at: Time.current)
      @proposal.start_submission!(user: @user, acknowledged: @acknowledged, override_reason: @override_reason, payload: payload, shadow: settings.shadow_mode?)
    end

    # The operator pressed approve and the desk said no: on the record, outside the rolled-back transaction.
    def refuse(message)
      AuditEvent.log("proposal_approval_refused", actor: @user ? :human : :system, user: @user, subject: @proposal, reason: message)
      raise Submission::Refused, message
    end

    def sizing_changed?
      return false unless @proposal.kind_entry?
      desk = Desk.new(account: @proposal.account)
      fresh = Sizing.for(limit_price: @proposal.limit_price, stop_price: @proposal.stop_price, equity: desk.balance_stale? ? nil : desk.equity,
                         rule: RiskRule.active_for("max_risk_per_trade", setup: @proposal.setup))
      fresh.quantity != @proposal.quantity.to_i
    end

    def payload
      symbol = @proposal.instrument.symbol
      if @proposal.kind_entry?
        Schwab::OrderPayload.bracket(symbol: symbol, quantity: @proposal.quantity, limit_price: @proposal.limit_price, stop_price: @proposal.stop_price)
      else
        Schwab::OrderPayload.sell(symbol: symbol, quantity: @proposal.quantity, limit_price: @proposal.limit_price, tax_lot_method: @proposal.tax_lot_method)
      end
    end
end
