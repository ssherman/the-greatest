# frozen_string_literal: true

module Services
  module Api
    # Turns a request's Authorization header into an ::Api::Principal, or a
    # single failure code the controller maps to an RFC 6750 response:
    #
    #   :unauthenticated     no Authorization header at all       -> 401, `Bearer`
    #   :invalid_token       wrong scheme, malformed, unknown, expired -> 401, `Bearer error="invalid_token"`
    #   :membership_required a person with no effective scope and no active membership -> 403, no challenge
    #
    # The only place that knows what a token IS. A session cookie is never
    # consulted: the API is stateless by design.
    #
    # Two kinds of bearer token: a personal access token (`tg_...`, Tokens), tried
    # first because it is recognised by its shape without a database read, and
    # then an OAuth access token a connector was issued through the sign-in flow
    # (Services::Oauth::AccessTokens). An OAuth token only works on the path of the resource its
    # connection was approved for (::Oauth::Resources.for_path), so it is
    # :invalid_token on /api/v1/* and on /api/mcp/admin. An OAuth token whose
    # holder lost their membership is :invalid_token, never :membership_required.
    #
    # One exception: a request dispatched in-process by the MCP server already
    # carries a principal in the Rack env (::Api::DispatchedRequest). It is
    # returned as is, with no second token lookup and no record_use. The MCP
    # dispatcher is the only writer of that key, and it has no HTTP_ prefix, so
    # no client header can set it.
    #
    # NOTE the root anchor on ::Api::Principal -- inside Services::Api a bare
    # `Api::Principal` resolves to Services::Api::Principal and raises.
    class Authenticator
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(request) = new(request).call

      def initialize(request)
        @request = request
      end

      def call
        dispatched = ::Api::DispatchedRequest.principal(@request.env)
        return success(dispatched) if dispatched

        header = @request.authorization
        return failure(:unauthenticated) if header.blank?

        secret = bearer_value(header)
        return failure(:invalid_token) if secret.nil?

        personal = Tokens.authenticate(secret)
        return authenticate_personal(personal) if personal

        oauth = ::Services::Oauth::AccessTokens.find_live(secret, resource: ::Oauth::Resources.for_path(@request.path))
        return failure(:invalid_token) if oauth.nil?

        authenticate_oauth(oauth)
      end

      private

      def authenticate_personal(token)
        user = token.user
        scopes = ::Api::Scopes.effective(token.scopes, user)
        return failure(:membership_required) if user.person? && scopes.empty? && !user.member?

        Tokens.record_use(token)
        success(::Api::Principal.new(user: user, token: token, scopes: scopes, tier: tier_for(user, scopes)))
      end

      # A connector's access token carries what the member approved, cut down to
      # what the member may hold today, like a personal token. Unlike a personal
      # token there is no 403 for a lapsed member: the person at the other end is
      # an agent that cannot act on "membership_required", so it gets the 401 that
      # sends it back through sign-in, where the member sees the real reason (D12).
      def authenticate_oauth(token)
        user = token.connection.user
        scopes = ::Api::Scopes.effective(token.connection.scopes, user)
        return failure(:invalid_token) if scopes.empty?

        ::Services::Oauth::AccessTokens.record_use(token)
        success(::Api::Principal.new(user: user, token: token, scopes: scopes, tier: tier_for(user, scopes)))
      end

      def tier_for(user, scopes)
        return :system if user.service?

        (scopes.any? { |scope| ::Api::Scopes.admin?(scope) }) ? :admin : :member
      end

      def bearer_value(header)
        scheme, value = header.strip.split(/\s+/, 2)
        return nil unless scheme&.casecmp?("Bearer")

        value&.strip.presence
      end

      def success(principal) = Result.new(success?: true, data: principal, errors: [])

      def failure(code) = Result.new(success?: false, data: nil, errors: [code])
    end
  end
end
