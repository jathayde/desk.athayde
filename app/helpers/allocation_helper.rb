module AllocationHelper
  # Fractions of equity as percentage points, signed for drift.
  def points(fraction, signed: false)
    return "unknown" if fraction.nil?
    value = number_with_precision(fraction.abs * 100, precision: 1)
    signed ? "#{fraction.negative? ? '−' : '+'}#{value} pts" : "#{value} pts"
  end

  def drift_action_label(drift)
    case drift.action
    when "none" then "within band"
    when "reported" then "outside band, #{rebalance_phrase(drift)}#{reported_note(drift.detail)}"
    when "unavailable" then "unavailable: #{Array(drift.detail["reasons"]).to_sentence}"
    when "proposed" then "#{rebalance_phrase(drift)} proposed"
    when "existing_proposal" then "outside band; a proposal on it is already waiting"
    when "rejected_standing" then "outside band; your last #{drift.detail["held"] ? "hold" : "rejection"} stands"
    when "thesis_review" then "outside band; a thesis review is waiting for you"
    else drift.action.humanize(capitalize: false)
    end
  end

  # One line per target from its latest drift row; the screen never recomputes it.
  def drift_summary(drift)
    return "not measured yet; the drift check runs after the close on trading days" if drift.nil?
    return "#{drift_action_label(drift)} · #{drift.as_of.strftime('%a %b %-d')}" if drift.action_unavailable?
    "weight #{percent(drift.weight)} · drift #{points(drift.drift, signed: true)} · band #{points(drift.band)} · #{drift_action_label(drift)} · #{drift.as_of.strftime('%a %b %-d')}"
  end

  def cash_drag_summary(drag, current: true)
    return "not checked yet" if drag.nil?
    cash = drag.cash_percent ? "#{percent(drag.cash_percent)} cash against #{percent(drag.intended_cash_percent)} the targets leave" : "no usable balance"
    weeks = drag.cash_percent ? ", #{pluralize(drag.weeks_in_cash, "week")} above the band" : ""
    "#{cash}#{weeks} (#{current ? "as of" : "last checked"} #{drag.as_of.strftime("%b %-d")})"
  end

  def cash_drag_flag(drag) = "past the #{drag.threshold_weeks}-week threshold under a policy of #{drag.deployment_policy&.summary || "none"}"
  def correlation_list(rows) = rows.map { "#{it.instrument.symbol} #{it.value.round(2)}" }
  def unmeasured_list(skipped) = skipped.map { |symbol, why| "#{symbol} (#{why})" }.to_sentence
  def correlation_heading(rows, current:) = "#{current ? "" : "last measured: "}#{rows.first.window_days} days to #{rows.first.last_close_on.strftime("%b %-d")}"
  def fund_flow_summary(flow) = flow ? flow.summary : "none entered"

  def drift_check_summary(event)
    return "never" if event.nil?
    "#{stamp(event.created_at)} · #{Hash(event.data["actions"]).map { |action, count| "#{count} #{action.humanize(capitalize: false)}" }.to_sentence.presence || "nothing measured"}"
  end

  def correlation_check_summary(event)
    return "never" if event.nil?
    skipped = unmeasured_list(Hash(event.data["skipped"])).presence
    "#{stamp(event.created_at)} · #{event.data["computed"]} computed#{", skipped #{skipped}" if skipped}"
  end

  private
    def reported_note(detail)
      return "; a class has no single instrument to order" if detail["class_target"]
      return "; under one whole share" if detail["sub_share"]
      return "; not proposed: #{detail["reason"]}" if detail["reason"]
      return "; buys wait while new cash is deployed" if detail["committed"]
      return "; under the #{money(BigDecimal(detail["below_minimum"]))} minimum" if detail["below_minimum"]
      return "; not proposed: #{detail["refused"]}" if detail["refused"]
      return "; not proposed: #{detail["error"]}" if detail["error"]
      ""
    end

    # "sell 11 sh · $620.00"; a class target has dollars but no shares.
    def rebalance_phrase(drift)
      [ drift.quantity ? "#{drift.side} #{drift.quantity} sh" : drift.side, money(drift.notional.abs) ].join(" · ")
    end
end
