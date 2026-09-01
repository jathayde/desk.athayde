class TradeLeg < ApplicationRecord
  belongs_to :trade
  belongs_to :activity, optional: true # nil only on the synthetic entry leg of a bootstrapped trade

  enum :kind, { entry: "entry", exit: "exit", adjustment: "adjustment", income: "income" }, prefix: true
end
