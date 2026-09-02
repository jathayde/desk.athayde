# One row, enforced by a check constraint on id = 1. Holds the global flags the PRD calls out:
# shadow mode (on by default), the manual halt, and why sync is paused.
class SystemSettings < ApplicationRecord
  # The one gate Phase 2's submission path asks before touching Schwab.
  def writes_allowed? = !shadow_mode? && !manual_halt?

  def self.instance = find_or_create_by!(id: 1)
end
