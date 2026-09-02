# The write tool for the watchlist (PRD §5.5, Flow 7): a symbol, what would trigger a look, and why.
class Agent::Tools::AddWatchlistItem < Agent::Tool
  tool description: "Add a symbol to the watchlist with the trigger that would make it a trade and the thesis behind it. " \
                    "The human reviews the list on /watchlist and proposes from it; this never proposes.",
       input: { symbol: { type: "string", minLength: 1, maxLength: 10 }, trigger: { type: "string", minLength: 1, maxLength: 500 }, thesis: { type: "string", maxLength: 2000 } },
       required: %i[ symbol trigger ],
       output: { watchlist_item_id: { type: "integer" }, symbol: { type: "string" }, status: { type: "string" } },
       read_only: false, scheduled: false

  def call(symbol:, trigger:, thesis: nil)
    item = WatchlistItem.create!(symbol: symbol, trigger: trigger, thesis: thesis, origin: :agent)
    { watchlist_item_id: item.id, symbol: item.symbol, status: item.status }
  rescue ActiveRecord::RecordInvalid => e
    raise InvalidArguments, e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise InvalidArguments, "#{symbol.to_s.upcase} is already watched"
  end
end
