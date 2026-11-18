# frozen_string_literal: true

module Services
  module EnrichmentQueue
    # The paid worker for one queue row, run by ResearchJob. It claims the
    # next row of the kind itself (no user: no admin is behind it), runs the
    # type's forced paid research and closes the row. Forced research ignores
    # research_via and the daily caps: running this worker is the decision to
    # spend.
    #
    # Claim has already deleted a row whose record is gone and closed one whose
    # gap is filled, so a row that reaches here has a live record that still
    # needs the work.
    #
    # Every exit after a successful claim ends in one guarded UPDATE (done or
    # failed), so no row is left claimed. The guard names the lease token: a row
    # another worker took over while this one researched is left to that worker.
    class Research
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(kind:)
        new(kind).call
      end

      def initialize(kind)
        @kind = kind
      end

      def call
        type = Registry.fetch(@kind)
        return failure("#{@kind} has no paid research path") unless type.paid_research?

        claimed = Claim.call(kind: @kind, limit: 1, user: nil)
        return failure(claimed.errors.join("; ")) unless claimed.success?

        request = claimed.data[:items].first
        return Result.new(success?: true, data: {request: nil}, errors: []) if request.nil?

        close(request, claimed.data[:lease_token], run(type, request))
      rescue Registry::UnknownKind => e
        failure(e.message)
      end

      private

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])

      # A raise is a failed run, not a crash: the job must not retry a paid call.
      def run(type, request)
        type.research(request)
      rescue => e
        Type::Result.new(success?: false, data: nil, errors: ["#{e.class}: #{e.message}"])
      end

      def close(request, token, outcome)
        statuses = ::EnrichmentRequest.statuses
        guarded = ::EnrichmentRequest.where(id: request.id, status: statuses.fetch("claimed"), lease_token: token)
        now = Time.current
        common = {resolved_via: ::EnrichmentRequest.resolved_via.fetch("paid_research"), resolved_at: now,
                  lease_token: nil, lease_expires_at: nil, updated_at: now}
        if outcome.success?
          changed = guarded.update_all(common.merge(status: statuses.fetch("done"), outcome: outcome.data[:outcome], error: nil,
            enrichment_id: outcome.data[:enrichment]&.id))
          status = "done"
        else
          changed = guarded.update_all(common.merge(status: statuses.fetch("failed"), error: outcome.errors.join("; ").first(Apply::MAX_ERROR)))
          status = "failed"
        end
        status = "taken_over" if changed.zero?
        ::Rails.logger.info("event=enrichment_queue_research kind=#{@kind} request_id=#{request.id} status=#{status}")

        return Result.new(success?: true, data: {request: nil}, errors: []) if changed.zero?
        return failure(outcome.errors.join("; ")) unless outcome.success?

        Result.new(success?: true, data: {request: request.reload}, errors: [])
      end
    end
  end
end
