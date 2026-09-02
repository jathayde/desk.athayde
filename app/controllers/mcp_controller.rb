# The Claude app's door. Bearer only, JSON only, stateless: the gem's transport handles the protocol.
class McpController < ActionController::API
  rate_limit to: 60, within: 1.minute, with: -> { render json: { error: "rate limited" }, status: :too_many_requests }
  before_action :require_bearer

  def handle
    status, headers, body = transport.call(request.env)
    response.headers.merge!(headers)
    self.status = status
    self.response_body = body
  end

  private
    def require_bearer
      presented = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1] # the scheme is case-insensitive; any other scheme is nobody
      expected = Rails.application.credentials.dig(:mcp, :bearer_token).to_s
      return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(presented.to_s, expected)
      response.headers["WWW-Authenticate"] = 'Bearer error="invalid_token"'
      render json: { error: "invalid_token" }, status: :unauthorized
    end

    # Rails host authorization owns the Host check (config.hosts in production), so the gem's DNS-rebinding
    # guard is off rather than fed a list it would match against itself.
    def transport
      MCP::Server::Transports::StreamableHTTPTransport.new(
        Agent::McpServer.build, stateless: true, enable_json_response: true, serve_subscriptions_listen: false,
        dns_rebinding_protection: false, max_request_bytes: 64.kilobytes
      )
    end
end
