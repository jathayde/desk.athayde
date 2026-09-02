module Agent
  # 16:30 New York on weekdays. The day's snapshot usually exists by then; the email says so when it does not.
  class EndOfDayJob < BriefJob
    private def kind = :eod
  end
end
