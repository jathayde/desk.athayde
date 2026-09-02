class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    # Approving, rejecting, overriding, editing rules, and toggling shadow mode belong to one person
    # (docs/phase-2-plan.md §0.13); the other user reads.
    def require_approver
      redirect_to root_path, alert: "Only the approver can do that." unless Current.user&.approver?
    end
end
