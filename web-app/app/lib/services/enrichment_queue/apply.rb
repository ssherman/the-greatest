module Services
  module EnrichmentQueue
    # Applies a submitted answer by calling the type, from ApplyJob. A failed
    # apply raises Failed, so Sidekiq retries it and the row stays submitted;
    # when retries run out the job calls fail!.
    #
    # The type may reach code (mergers, the ledger) that records who acted, so
    # Current carries the submitter's identity while it runs and is restored
    # afterwards, even if the type raises.
    class Apply
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      class Failed < StandardError; end

      MAX_ERROR = 1_000

      def self.call(request_id:)
        new(request_id).call
      end

      def self.fail!(request_id:, error:)
        ::EnrichmentRequest
          .where(id: request_id)
          .where.not(status: ::EnrichmentRequest.statuses.fetch("done"))
          .update_all(status: ::EnrichmentRequest.statuses.fetch("failed"), error: error.to_s.first(MAX_ERROR),
            lease_token: nil, lease_expires_at: nil, updated_at: Time.current)
      end

      def initialize(request_id)
        @request_id = request_id
      end

      def call
        request = ::EnrichmentRequest.find_by(id: @request_id)
        return noop unless request&.submitted?

        if request.enrichable.nil?
          request.delete
          return noop
        end

        result = with_acting(request) { Registry.fetch(request.kind).apply(request) }
        raise Failed, "apply failed for request #{request.id}: #{Array(result.errors).join("; ")}" unless result.success?

        request.update!(status: :done, outcome: result.data[:outcome], enrichment: result.data[:enrichment],
          lease_token: nil, lease_expires_at: nil)
        Result.new(success?: true, data: {request: request}, errors: [])
      end

      private

      def noop = Result.new(success?: true, data: nil, errors: [])

      def with_acting(request)
        previous = [Current.acting_user, Current.acting_via]
        Current.acting_user = request.resolved_by
        Current.acting_via = request.resolved_via
        yield
      ensure
        Current.acting_user, Current.acting_via = previous
      end
    end
  end
end
