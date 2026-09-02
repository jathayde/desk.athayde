# Where a stop may sit (PRD §5.4.1): several standard methods over Schwab's daily history, bounded by the
# percent stop as a floor. Data that cannot support the methods is a refusal, never a guess.
module StopCollar
  Collar = Data.define(:methods, :tight, :wide, :floor, :floor_dominates, :quality, :refusal) do
    def ok? = quality == :ok
    def to_h = Agent.serialize(super)
  end
end
