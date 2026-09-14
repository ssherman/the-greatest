# frozen_string_literal: true

module Services
  module Api
    # Turns a request's Authorization header into an ::Api::Principal, or a
    # single failure code the controller maps to an RFC 6750 response:
    #
    #   :unauthenticated     no Authorization header at all       -> 401, `Bearer`
    #   :invalid_token       wrong scheme, malformed, unknown, expired -> 401, `Bearer error="invalid_token"`
    #   :membership_required a person whose membership is not active -> 403, no challenge
    #
    # The only place that knows what a token IS. A session cookie is never
    # consulted: the API is stateless by design.
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
        header = @request.authorization
        return failure(:unauthenticated) if header.blank?

        token = bearer_value(header).then { |secret| secret && ApiToken.authenticate(secret) }
        return failure(:invalid_token) if token.nil?

        user = token.user
        return failure(:membership_required) if user.person? && !user.member?

        token.touch_last_used!
        success(::Api::Principal.new(
          user: user,
          token: token,
          scopes: token.scopes,
          tier: user.service? ? :system : :member
        ))
      end

      private

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
