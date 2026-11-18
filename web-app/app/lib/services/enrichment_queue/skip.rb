module Services
  module EnrichmentQueue
    # An agent gives up on a claimed item. The reason goes in note; outcome is
    # the fixed "skipped_by_agent" so outcome counts stay a small closed set.
    # Same check order as Submit: a wrong token is a conflict before anything
    # about the reason is judged.
    class Skip
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      MAX_REASON = 500
      OUTCOME = "skipped_by_agent"

      def self.call(request:, lease_token:, reason:, user:, via: "api")
        new(request: request, lease_token: lease_token, reason: reason, user: user, via: via).call
      end

      def initialize(request:, lease_token:, reason:, user:, via:)
        @request = request
        @lease_token = lease_token
        @reason = reason
        @user = user
        @via = via.to_s
      end

      def call
        unless @request.claimed? && @request.lease_token == @lease_token
          return failure(:conflict, "the request is #{@request.status} and the lease token does not match a claimed request")
        end
        unless @reason.is_a?(String) && @reason.strip.present? && @reason.length <= MAX_REASON
          return failure(:invalid, "reason must be 1 to #{MAX_REASON} characters")
        end

        now = Time.current
        updated = ::EnrichmentRequest
          .where(id: @request.id, status: ::EnrichmentRequest.statuses.fetch("claimed"), lease_token: @lease_token)
          .update_all(status: ::EnrichmentRequest.statuses.fetch("skipped"), outcome: OUTCOME, note: @reason,
            lease_token: nil, lease_expires_at: nil, resolved_by_id: @user.id,
            resolved_via: ::EnrichmentRequest.resolved_via.fetch(@via), resolved_at: now, updated_at: now)
        return failure(:conflict, "the lease is no longer valid") unless updated == 1

        Result.new(success?: true, data: {request: @request.reload}, errors: [])
      end

      private

      def failure(code, detail) = Result.new(success?: false, data: nil, errors: [{code: code, detail: detail}])
    end
  end
end
