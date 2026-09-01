module Schwab
  # Equity session times for one date. A closed day has no sessionHours (shape SCHWAB_SHAPE_UNVERIFIED).
  MarketHours = Data.define(:date, :open, :session_opens_at, :regular_opens_at, :regular_closes_at, :session_closes_at, :raw) do
    def self.from(raw, date:)
      equity = (raw["equity"] || {}).values.first || {}
      sessions = equity["sessionHours"] || {}
      pre = span(sessions["preMarket"])
      regular = span(sessions["regularMarket"])
      post = span(sessions["postMarket"])
      new(date: date.to_date, open: equity["isOpen"] == true && regular.present?,
          session_opens_at: (pre || regular)&.first, regular_opens_at: regular&.first,
          regular_closes_at: regular&.last, session_closes_at: (post || regular)&.last, raw: raw)
    end

    def self.span(intervals)
      return nil if intervals.blank?
      starts = intervals.map { |i| Timestamp.parse(i["start"]) }
      ends = intervals.map { |i| Timestamp.parse(i["end"]) }
      [ starts.min, ends.max ]
    end

    def open? = open
  end
end
