# What the Hotwire Native shell reads before anything else (docs/phase-2-plan.md §10): the defaults, which
# paths open as modals, and which of the mobile-first screens refresh on a pull. Public, since the shell
# fetches it before sign-in. Unversioned on purpose: one build, two users, and the shell re-reads it on launch.
class Native::PathConfigurationsController < ApplicationController
  allow_unauthenticated_access

  RULES = [
    { patterns: [ ".*" ], properties: { context: "default", pull_to_refresh_enabled: false } },
    { patterns: [ "/new$", "/edit$", "^/session", "^/magic_link", "^/risk_rules", "^/schwab/" ], properties: { context: "modal" } },
    { patterns: [ "^/$", "^/proposals/\\d+$", "^/trades/\\d+$" ], properties: { pull_to_refresh_enabled: true } }
  ].freeze

  def show
    render json: { settings: { screenshots_enabled: false }, rules: RULES }
  end
end
