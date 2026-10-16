# What the desk does with new cash (PRD §5.12.3, docs/phase-2.5-plan.md §0.1): deploy it at once, stage it over N
# weekly tranches, or ask each time. One active row, versioned by superseding exactly like a rule.
class DeploymentPolicy < ApplicationRecord
  include Superseding

  MODE_LABELS = { "immediate" => "deploy at once", "staged" => "stage over weeks", "ask" => "ask each time" }.freeze

  enum :mode, MODE_LABELS.keys.index_by(&:itself), validate: true

  validates :weeks, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 52 }, if: :staged?
  normalizes :weeks, with: ->(weeks) { weeks.presence }

  def self.current = active.first

  def supersede!(mode:, weeks:, user:, note: nil, override_reason: nil)
    supersede_with!({ mode: mode, weeks: (weeks if mode.to_s == "staged") }, user: user, note: note, override_reason: override_reason) do |successor, override|
      AuditEvent.log("deployment_policy_changed", actor: :human, user: user, subject: successor, reason: successor.note,
                     data: { before: { mode: self.mode, weeks: self.weeks }, after: { mode: successor.mode, weeks: successor.weeks },
                             version: successor.version, during_halt: override.present?, override_reason: override })
    end
  end

  def summary = staged? ? "staged over #{weeks} #{"week".pluralize(weeks)}" : MODE_LABELS.fetch(mode)
end
