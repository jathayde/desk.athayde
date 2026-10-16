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
    when "reported" then "outside band, #{rebalance_phrase(drift)}"
    when "unavailable" then "unavailable: #{Array(drift.detail["reasons"]).to_sentence}"
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
    # "sell 11 sh · $620.00"; a class target has dollars but no shares.
    def rebalance_phrase(drift)
      side = drift.notional.positive? ? "buy" : "sell"
      [ drift.quantity ? "#{side} #{drift.quantity} sh" : side, money(drift.notional.abs) ].join(" · ")
    end
end
