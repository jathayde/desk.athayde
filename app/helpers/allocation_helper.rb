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
    when "rejected_standing" then "outside band; your last rejection stands"
    else drift.action.humanize(capitalize: false)
    end
  end

  # One line per target from its latest drift row; the screen never recomputes it.
  def drift_summary(drift)
    return "not measured yet; the drift check runs after the close on trading days" if drift.nil?
    return "#{drift_action_label(drift)} · #{drift.as_of.strftime('%a %b %-d')}" if drift.action_unavailable?
    "weight #{percent(drift.weight)} · drift #{points(drift.drift, signed: true)} · band #{points(drift.band)} · #{drift_action_label(drift)} · #{drift.as_of.strftime('%a %b %-d')}"
  end

  private
    def reported_note(detail)
      return "; a class has no single instrument to order" if detail["class_target"]
      return "; held for a thesis review" if detail["held_for"]
      return "; under one whole share" if detail["sub_share"]
      return "; not proposed: #{detail["reason"]}" if detail["reason"]
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
