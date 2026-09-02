# Which of a trade's lots a sell consumes under a lot method (docs/phase-2-plan.md §0.11): the open lots in
# the method's order, with the quantity the sale takes from each, frozen on the proposal at draft.
module Proposals::Lots
  ORDERS = {
    "FIFO" => ->(lots) { lots.sort_by { |l| l[:acquired_at] || Time.at(0) } },
    "LIFO" => ->(lots) { lots.sort_by { |l| l[:acquired_at] || Time.at(0) }.reverse },
    "HIGH_COST" => ->(lots) { lots.sort_by { |l| -(l[:price] || 0) } },
    "LOW_COST" => ->(lots) { lots.sort_by { |l| l[:price] || 0 } }
  }.freeze

  def self.for(trade, quantity:, method:)
    lots = Array(trade&.tax_lots).map(&:to_h)
    remaining = quantity.to_d
    ORDERS.fetch(method).call(lots).map do |lot|
      selling = [ lot[:quantity], remaining ].min.clamp(0..)
      remaining -= selling
      Agent.serialize(lot.merge(selling: selling))
    end
  end
end
