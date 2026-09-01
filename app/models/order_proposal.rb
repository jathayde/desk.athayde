class OrderProposal < ApplicationRecord
  belongs_to :account
  belongs_to :instrument
  belongs_to :target_order, class_name: "Order", optional: true
  belongs_to :user, optional: true
  belongs_to :setup, optional: true
  has_many :orders, dependent: :restrict_with_exception
  has_many :submission_attempts, dependent: :restrict_with_exception
  has_one :trade, dependent: :restrict_with_exception

  enum :kind, { entry: "entry", exit: "exit", stop_adjustment: "stop_adjustment" }, prefix: true
  enum :origin, { agent: "agent", human: "human" }
  enum :status, {
    proposed: "proposed", validated: "validated", rejected: "rejected", approved: "approved",
    submitted: "submitted", submission_unknown: "submission_unknown", filled: "filled", cancelled: "cancelled"
  }
end
