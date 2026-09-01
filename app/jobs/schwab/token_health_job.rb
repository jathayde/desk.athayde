module Schwab
  # Runs 08:00 and 20:00 ET. Nags when there is no usable token (every run), on Monday and Tuesday when the
  # token will not outlive the coming Sunday email, and once per token when it enters the 24-hour window
  # without the Sunday email covering it.
  class TokenHealthJob < ApplicationJob
    SUNDAY_EMAIL_HOUR = 18

    def perform
      token = SchwabToken.current
      reason = nag_reason(token)
      return unless reason
      TokenMailer.nag(reason, token).deliver_now
      AuditEvent.log("token_nag_sent", actor: :system, subject: token, reason: reason.to_s)
    end

    private
      def nag_reason(token)
        return :missing if token.nil?
        return :revoked if token.revoked?
        return :expired if token.refresh_expired?
        return :missed_sunday if missed_sunday?(token)
        return :expiring if token.refresh_expiring_soon? && !covered_by_sunday_email?(token) && !already_warned?(token)
        nil
      end

      # A 168-hour token issued before the most recent Sunday email cannot reach the next one.
      def missed_sunday?(token)
        now = Time.current
        return false unless now.monday? || now.tuesday?
        token.issued_at < sunday_email(now.beginning_of_week(:sunday))
      end

      # The weekly ritual already covers a token that lives past the coming Sunday email.
      def covered_by_sunday_email?(token)
        token.refresh_expires_at >= coming_sunday_email
      end

      def coming_sunday_email
        now = Time.current
        today = sunday_email(now.beginning_of_day)
        return today if now.sunday? && now < today
        sunday_email(now.next_occurring(:sunday).beginning_of_day)
      end

      def sunday_email(sunday) = sunday.change(hour: SUNDAY_EMAIL_HOUR)

      def already_warned?(token)
        AuditEvent.where(kind: "token_nag_sent", subject: token, reason: "expiring").exists?
      end
  end
end
