# The allocation module (PRD §5.12, docs/phase-2.5-plan.md): targets and drift that judge the whole book. Nothing
# here places or sizes an order; what it proposes goes through the same proposal and approval pipeline.
module Allocation
  # Allocation proposals stay in shadow, whatever the desk's shadow mode, until the Schwab shapes they depend on are
  # confirmed: a plain LIMIT with no child accepted (docs/verify-on-approval.md item 60) and whether the 17:10 price
  # is an after-hours print (item 64). Flipping this is a deliberate commit, after those checks, never a setting.
  ORDERS_VERIFIED = false

  def self.table_name_prefix = "allocation_"
end
