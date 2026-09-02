# Where the review flow goes after acting on a trade: the next one waiting, else the queue.
module ReviewFlow
  private
    def next_review_path(trade)
      following = Trade.next_to_review(after: trade)
      following ? trade_review_path(following) : trades_path(filter: "needs_review")
    end
end
