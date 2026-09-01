class RiskRule < ApplicationRecord
  belongs_to :setup, optional: true
  belongs_to :superseded_by, class_name: "RiskRule", optional: true

  scope :active, -> { where(active: true) }
end
