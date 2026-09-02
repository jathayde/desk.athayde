module Schwab
  # Runs 08:00 and 20:00 ET. Nags when there is no usable token (every run), on Monday and Tuesday when the
  # token will not outlive the coming Sunday email, and once per token when it enters the 24-hour window
  # without the Sunday email covering it.
  class TokenHealthJob < ApplicationJob
    def perform
      token = SchwabToken.current
      reason = nag_reason(token)
      return unless reason
      TokenMailer.nag(reason, token).deliver_now
      AuditEvent.log("token_nag_sent", actor: :system, subject: token, reason: reason.to_s)
    end

    private
      def nag_reason(token)
        case SchwabToken.status(token)
        when :missing, :revoked, :expired then SchwabToken.status(token)
        else
          return :missed_sunday if missed_sunday?(token)
          :expiring if token.refresh_expiring_soon? && !covered_by_sunday_email?(token) && !already_warned?(token)
        end
      end

      # A 168-hour token issued before the most recent Sunday email cannot reach the next one.
      def missed_sunday?(token)
        now = Time.current
        return false unless now.monday? || now.tuesday?
        token.issued_at < SchwabToken.most_recent_sunday_email(now)
      end

      # The weekly ritual already covers a token that lives past the coming Sunday email.
      def covered_by_sunday_email?(token) = token.covered_by_sunday_email?

      def already_warned?(token)
        AuditEvent.where(kind: "token_nag_sent", subject: token, reason: "expiring").exists?
      end
  end
end
