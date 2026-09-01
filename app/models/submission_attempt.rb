class SubmissionAttempt < ApplicationRecord
  belongs_to :order_proposal
  belongs_to :reconciled_order, class_name: "Order", optional: true

  enum :outcome, { submitted: "submitted", unknown: "unknown", failed: "failed", reconciled: "reconciled", shadowed: "shadowed" }
end
