module ApplicationHelper
  PROTECTION_LABELS = {
    protected: "protected", partial: "partially covered", oversized: "stop larger than position", awaiting: "stop awaiting parent",
    trailing_unknown: "trailing stop, price unknown", unpriced: "stop in place, price unknown", unprotected: "no stop", delisted: "delisted"
  }.freeze
  OUTCOME_LABELS = { "pass" => "pass", "caution" => "caution, acknowledge", "block" => "blocks", "unavailable" => "not checked, acknowledge", "skipped" => "does not apply" }.freeze
  REVIEW_REASON_LABELS = {
    "missing_setup" => "No setup recorded", "missing_stop" => "No planned stop", "bootstrapped" => "Legacy holding: the entry predates the journal",
    "ordering_ambiguous" => "Fills arrived out of order", "corporate_action" => "Corporate action needs a look", "position_missing" => "Open trade with no position at the broker"
  }.freeze

  def money(amount, precision: 2)
    return "unavailable" if amount.nil?
    number_to_currency(amount, precision: precision)
  end

  def signed_money(amount)
    return "unavailable" if amount.nil?
    "#{amount.negative? ? '−' : '+'}#{number_to_currency(amount.abs)}"
  end

  def percent(ratio, precision: 1)
    return "unknown" if ratio.nil?
    number_to_percentage(ratio * 100, precision: precision)
  end

  def signed_percent(ratio)
    return "unknown" if ratio.nil?
    "#{ratio.negative? ? '−' : '+'}#{number_to_percentage(ratio.abs * 100, precision: 1)}"
  end

  def r_multiple(trade) = trade.realized_r ? "#{'%+.2f' % trade.realized_r}R" : signed_money(trade.realized_pnl)

  def as_of(time, stale: false)
    return tag.span("never", class: "as-of stale") if time.nil?
    tag.time(stale ? "stale · #{time_ago_in_words(time)} ago" : "#{time_ago_in_words(time)} ago", datetime: time.iso8601, title: l(time, format: :weekday_time), class: [ "as-of", ("stale" if stale) ])
  end

  # An absolute stamp for email, where relative words age badly.
  def stamp(time) = time ? l(time, format: :stamp) : "never"
  def protection_label(protection) = PROTECTION_LABELS.fetch(protection)
  def proposal_links(proposals) = safe_join(proposals.map { |proposal| link_to(proposal.instrument.symbol, proposal_path(proposal)) }, ", ")

  def proposals_summary(desk)
    [ ("#{desk.pending_proposal_count} waiting" if desk.pending_proposal_count.positive?),
      ("#{desk.hand_placement_count} to place by hand" if desk.hand_placement_count.positive?) ].compact.to_sentence.presence || "none waiting"
  end
  def outcome_label(outcome) = OUTCOME_LABELS.fetch(outcome.to_s)
  def outcome_class(outcome) = { "block" => "warn", "caution" => "warn" }[outcome.to_s]
  def detail_summary(detail, limit: 160) = detail.map { |key, value| "#{key} #{value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value}" }.join(" · ").truncate(limit)
  def review_reason_label(trade) = REVIEW_REASON_LABELS.fetch(trade.review_reason.to_s, "Needs a look")
  def excluded_summary(by_reason) = by_reason.map { |reason, n| "#{n} #{protection_label(reason)}" }.to_sentence

  def quantity(q) = q.nil? ? "" : q.to_s("F").sub(/\.0+\z/, "")

  def nav_link(name, path)
    link_to name, path, class: [ "nav-link", ("active" if current_page?(path) || (path != root_path && request.path.start_with?(path))) ]
  end
end
