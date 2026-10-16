# Policy as versioned rows (docs/phase-2-plan.md §0.8, docs/phase-2.5-plan.md §0.1): one active row, edited by
# superseding, never in place, so whatever a version judged keeps pointing at it. The including model supplies
# the successor's attributes and writes its own audit row inside the same transaction.
module Superseding
  extend ActiveSupport::Concern

  # Raised when a halt is engaged and no override reason was given: the editor is locked, by design, so policy
  # cannot be loosened in the heat of the moment without saying why.
  class Locked < StandardError; end

  included do
    belongs_to :superseded_by, class_name: name, optional: true
    belongs_to :changed_by, class_name: "User", optional: true

    scope :active, -> { where(active: true) }
  end

  private
    # Under this row's lock and the settings lock, so two edits cannot both mint version n+1 and a halt landing
    # mid-edit still locks. Yields the successor and the override reason (nil without one) for the audit row.
    def supersede_with!(attributes, user:, note:, override_reason:)
      override = override_reason.to_s.strip.presence
      transaction do
        lock!
        raise ActiveRecord::StaleObjectError.new(self, "supersede") unless active?
        raise Locked, "Policy is locked while a halt is engaged; say why you are editing anyway." if SystemSettings.instance.lock!.halted? && override.nil?
        update!(active: false) # first, so the one-active index admits the successor
        successor = self.class.create!(attributes.merge(version: version + 1, changed_by: user,
                                                        note: [ note.presence, ("override during halt: #{override}" if override) ].compact.join(" · ").presence))
        update!(superseded_by: successor)
        yield successor, override
        successor
      end
    end
end
