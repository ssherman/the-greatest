module Services
  module EnrichmentQueue
    # Runs the apply job again for a row that already holds the agent's answer, so
    # a transient failure (a model outage inside the categories chooser call) does
    # not cost the research. Two rows qualify: a failed row that holds an answer,
    # and a submitted row whose job has been silent for STALE_AFTER (a lost Redis
    # queue leaves one stuck, and nothing else moves it). A fresh submitted row is
    # still being applied and is refused.
    class RetryApply
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      STALE_AFTER = 15.minutes

      def self.call(request:, user:)
        new(request: request, user: user).call
      end

      def initialize(request:, user:)
        @request = request
        @user = user
      end

      def call
        row = ::EnrichmentRequest.find_by(id: @request.id)
        return conflict("the request no longer exists") unless row

        previous_error = row.error
        if row.failed?
          return conflict("a failed request with no stored answer has nothing to apply again; re-queue it instead") if row.answer.blank?

          failed = ::EnrichmentRequest.statuses.fetch("failed")
          claimed = update_scope(row, failed).update_all(
            status: ::EnrichmentRequest.statuses.fetch("submitted"), error: nil, resolved_at: Time.current, updated_at: Time.current
          )
        elsif row.submitted?
          return conflict("it is still being applied; retry only after #{STALE_AFTER.inspect} without a result") unless stale?(row)

          claimed = update_scope(row, ::EnrichmentRequest.statuses.fetch("submitted"))
            .where("resolved_at IS NULL OR resolved_at < ?", STALE_AFTER.ago)
            .update_all(resolved_at: Time.current, updated_at: Time.current)
        else
          return conflict("only a failed request with an answer, or a submitted request stuck for #{STALE_AFTER.inspect}, can be retried")
        end
        return conflict("the request changed while retrying; reload and look again") unless claimed == 1

        queue(row, row.failed?, previous_error)
      end

      private

      def update_scope(row, status)
        ::EnrichmentRequest.where(id: row.id, status: status)
      end

      def stale?(row)
        row.resolved_at.nil? || row.resolved_at < STALE_AFTER.ago
      end

      def queue(row, was_failed, previous_error)
        ::EnrichmentQueue::ApplyJob.perform_async(row.id)
        Rails.logger.info("event=enrichment_queue_retry_apply request_id=#{row.id} user_id=#{@user.id}")
        Result.new(success?: true, data: {request: row.reload}, errors: [])
      rescue => e
        if was_failed
          ::EnrichmentRequest.where(id: row.id, status: ::EnrichmentRequest.statuses.fetch("submitted"))
            .update_all(status: ::EnrichmentRequest.statuses.fetch("failed"), error: previous_error, updated_at: Time.current)
        end
        conflict("the job could not be queued: #{e.class}: #{e.message}")
      end

      def conflict(detail)
        Result.new(success?: false, data: nil, errors: [{code: :conflict, detail: detail}])
      end
    end
  end
end
