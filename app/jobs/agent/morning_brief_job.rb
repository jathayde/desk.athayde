module Agent
  # 07:00 New York on weekdays; the calendar row decides whether the day trades.
  class MorningBriefJob < BriefJob
    private def kind = :morning_brief
  end
end
