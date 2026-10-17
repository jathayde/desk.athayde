# The quote an approval saw (docs/phase-2.6-plan.md §0.8): fetched fresh before the approval takes its lock, frozen
# on the proposal and in its audit row, and the mid the fill's cost is later measured against. Shadow mode reads it
# too; it is a read, not an order. Any failure, a rate limit included, is recorded as unavailable and never refuses.
module Submission::ApprovalQuote
  OLD = 30.seconds # a quote this much older than its fetch is marked stale: outside the session, most are

  def self.fetch(instrument)
    fetched_at = Time.current
    quote = Schwab::Quote.batch(Schwab.client(wait: false).quotes([ instrument.symbol ])).quotes.find { it.symbol == instrument.symbol }
    return unavailable("Schwab returned no quote for #{instrument.symbol}", fetched_at) unless quote
    return unavailable("the quote's CUSIP #{quote.cusip} is not #{instrument.symbol}'s", fetched_at) if quote.cusip.present? && instrument.cusip.present? && quote.cusip != instrument.cusip
    { "bid" => quote.bid&.to_s, "ask" => quote.ask&.to_s, "mark" => quote.mark&.to_s, "last" => quote.last&.to_s, "quote_time" => quote.quote_time&.iso8601,
      "fetched_at" => fetched_at.iso8601, "stale" => quote.quote_time.nil? || quote.quote_time < fetched_at - OLD }
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { approval_quote: instrument.symbol }) unless e.is_a?(Schwab::Error)
    unavailable(e.message.truncate(120), fetched_at)
  end

  def self.unavailable(reason, fetched_at) = { "unavailable" => reason, "fetched_at" => fetched_at.iso8601 }
end
