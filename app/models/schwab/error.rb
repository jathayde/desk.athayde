module Schwab
  class Error < StandardError
    attr_reader :status, :body, :request_id, :attempts

    def initialize(message = nil, status: nil, body: nil, request_id: nil, attempts: 1)
      super(message || self.class.name.demodulize.titleize)
      @status, @body, @request_id, @attempts = status, body, request_id, attempts
    end

    # Builds the right subclass for an HTTP response. The body is scrubbed before anything reads it.
    def self.for_response(response, attempts:, idempotent:)
      status = response.code.to_i
      body = Scrub.body(response.body)
      json = JSON.parse(body) rescue nil
      message = "Schwab responded #{status}: #{summarize(json, body)}"
      opts = { status: status, body: body, request_id: request_id_in(json), attempts: attempts }
      case status
      when 401 then AuthError.new(message, **opts)
      when 429 then RateLimited.new(message, retry_after: retry_after_in(response), **opts)
      when 400..499 then RequestError.new(message, **opts)
      when 500.. then (idempotent ? ServerError : UnknownOutcome).new(message, **opts)
      else new(message, **opts)
      end
    end

    def self.summarize(json, body)
      return body.to_s.truncate(200) unless json.is_a?(Hash)
      Array(json["errors"]).filter_map { |e| e["detail"] || e["title"] }.join("; ").presence ||
        json["error_description"] || json["error"] || body.to_s.truncate(200)
    end

    def self.request_id_in(json) = json.is_a?(Hash) ? Array(json["errors"]).first&.dig("id") : nil

    def self.retry_after_in(response)
      seconds = response["Retry-After"].to_i
      seconds.positive? ? seconds : nil
    end
  end

  class AuthError < Error; end
  class ReauthRequired < AuthError; end   # token endpoint says the grant is dead: the pause path
  class RateLimited < Error
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil, **opts)
      super(message, **opts)
      @retry_after = retry_after
    end
  end
  class ServerError < Error; end
  class RequestError < Error; end          # 4xx other than auth and rate limit: our parameters are wrong; never retried
  class TransportError < Error; end        # timeout or connection failure on an idempotent call
  class UnknownOutcome < Error; end        # the same on a non-idempotent call; Phase 2 depends on this being distinct
  class MappingError < Error; end          # required field missing or malformed; rescued per record by sync
  class NotConfigured < Error; end         # app credentials missing; raised before any request is built
end
