class TradeLeg < ApplicationRecord
  belongs_to :trade
  belongs_to :activity, optional: true # nil only on the synthetic plug leg of a bootstrapped trade

  enum :kind, { entry: "entry", exit: "exit", adjustment: "adjustment", income: "income" }, prefix: true

  def plug? = activity_id.nil? && kind_entry?
end
