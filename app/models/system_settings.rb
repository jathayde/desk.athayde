# One row, enforced by a check constraint on id = 1. Holds the global flags the PRD calls out:
# shadow mode (on by default), the manual halt, and why sync is paused.
class SystemSettings < ApplicationRecord
  def self.instance = find_or_create_by!(id: 1)

  def halted? = manual_halt
end
