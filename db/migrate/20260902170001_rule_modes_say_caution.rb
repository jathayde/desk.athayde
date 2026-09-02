# One word for the outcome the approver acknowledges: the rule's mode and the report's outcome both say caution.
class RuleModesSayCaution < ActiveRecord::Migration[8.1]
  def up = execute("UPDATE risk_rules SET mode = 'caution' WHERE mode = 'warn'")
  def down = execute("UPDATE risk_rules SET mode = 'warn' WHERE mode = 'caution'")
end
