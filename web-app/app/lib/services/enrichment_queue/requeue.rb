module Services
  module EnrichmentQueue
    # Puts a finished row (done, skipped or failed) back in the queue. Open and
    # in-flight rows are refused: re-queueing a claimed or submitted row would
    # race the agent or the apply job that holds it.
    class Requeue
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      REQUEUEABLE = %w[done skipped failed].freeze

      def self.call(request:, user:)
        new(request: request, user: user).call
      end

      def initialize(request:, user:)
        @request = request
        @user = user
      end

      def call
        statuses = ::EnrichmentRequest.statuses
        type = Registry.fetch(@request.kind)
        updated = ::EnrichmentRequest
          .where(id: @request.id, status: REQUEUEABLE.map { |name| statuses.fetch(name) })
          .update_all(::EnrichmentRequest::REOPEN_RESET.merge(reason: "manual", version: type.version, updated_at: Time.current))
        unless updated == 1
          return Result.new(success?: false, data: nil,
            errors: [{code: :conflict, detail: "only a done, skipped or failed request can be re-queued"}])
        end

        Rails.logger.info("event=enrichment_queue_requeue request_id=#{@request.id} user_id=#{@user.id}")
        Result.new(success?: true, data: {request: @request.reload}, errors: [])
      end
    end
  end
end
