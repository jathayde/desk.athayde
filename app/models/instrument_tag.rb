# An authored flag on an instrument (docs/phase-2.5-plan.md §0.3): leveraged and amplified instruments never get a
# mechanical proposal; a diversifier is watched for correlation with SPY.
class InstrumentTag < ApplicationRecord
  TAGS = %w[ leveraged amplified diversifier ].freeze

  belongs_to :instrument

  validates :tag, inclusion: { in: TAGS }, uniqueness: { scope: :instrument_id }
end
