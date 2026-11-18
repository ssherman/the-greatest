module Services
  module EnrichmentQueue
    # Stores an agent's answer on a claimed row and queues the job that applies
    # it. Applying can call a model for several seconds, so it never happens in
    # the web request.
    #
    # Checks run in a fixed order so the caller can tell "your lease is gone"
    # from "your answer is malformed": the idempotent repeat first, then state
    # and lease (:conflict), then input (:invalid). A wrong token is therefore
    # always a conflict, even when the answer is also bad.
    #
    # The move to submitted is one conditional UPDATE, so two concurrent submits
    # with the same token cannot both win and both queue a job.
    class Submit
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      MAX_ANSWER_BYTES = 50_000
      MAX_NOTE = 1_000
      MAX_SOURCES = 20
      MAX_URL = 2_000
      MAX_SCHEMA_ERRORS = 5

      def self.call(request:, lease_token:, answer:, sources:, user:, note: nil, via: "api")
        new(request: request, lease_token: lease_token, answer: answer, sources: sources, note: note, user: user, via: via).call
      end

      def initialize(request:, lease_token:, answer:, sources:, note:, user:, via:)
        @request = request
        @lease_token = lease_token
        @answer = answer
        @sources = sources
        @note = note
        @user = user
        @via = via.to_s
      end

      def call
        stored = state_failure(@request)
        return stored unless stored.nil?

        invalid = input_failure
        return invalid if invalid

        now = Time.current
        updated = ::EnrichmentRequest
          .where(id: @request.id, status: ::EnrichmentRequest.statuses.fetch("claimed"), lease_token: @lease_token)
          .update_all(status: ::EnrichmentRequest.statuses.fetch("submitted"), answer: @answer, sources: @sources, note: @note,
            resolved_by_id: @user.id, resolved_via: ::EnrichmentRequest.resolved_via.fetch(@via), resolved_at: now, updated_at: now)

        if updated == 1
          enqueue_or_revert
          return success(@request.reload)
        end

        # Lost the race: the stored row now says whether this was a repeat or a conflict.
        fresh = ::EnrichmentRequest.find_by(id: @request.id)
        (fresh && state_failure(fresh)) || failure(:conflict, "the lease is no longer valid")
      end

      private

      # If the job cannot be queued (Redis down) the row would sit submitted with
      # nothing to apply it, and the agent's retry would be answered as an
      # idempotent success. So put the row back to claimed and re-raise: the
      # caller sees the failure and a retry redoes the submit.
      def enqueue_or_revert
        ::EnrichmentQueue::ApplyJob.perform_async(@request.id)
      rescue
        ::EnrichmentRequest
          .where(id: @request.id, status: ::EnrichmentRequest.statuses.fetch("submitted"), lease_token: @lease_token)
          .update_all(status: ::EnrichmentRequest.statuses.fetch("claimed"), answer: nil, sources: [], note: nil,
            resolved_by_id: nil, resolved_via: nil, resolved_at: nil, updated_at: Time.current)
        raise
      end

      # nil when the row is claimed under our token (go on). A success when it is
      # already submitted under our token (the idempotent repeat). Otherwise a conflict.
      def state_failure(row)
        return success(row) if row.submitted? && row.lease_token == @lease_token
        return nil if row.claimed? && row.lease_token == @lease_token

        failure(:conflict, "the request is #{row.status} and the lease token does not match a claimed request")
      end

      def input_failure
        type = Registry.fetch(@request.kind)
        return failure(:invalid, "answer must be an object") unless @answer.is_a?(Hash)
        return failure(:invalid, "answer is larger than #{MAX_ANSWER_BYTES} bytes") if @answer.to_json.bytesize > MAX_ANSWER_BYTES

        messages = JSONSchemer.schema(type.answer_schema).validate(@answer).first(MAX_SCHEMA_ERRORS).map { |error| error["error"] }
        return failure(:invalid, messages.join("; ")) if messages.any?

        if @note && (!@note.is_a?(String) || @note.length > MAX_NOTE)
          return failure(:invalid, "note must be a string of at most #{MAX_NOTE} characters")
        end

        problem = source_problem
        failure(:invalid, problem) if problem
      rescue Registry::UnknownKind => e
        failure(:invalid, e.message)
      end

      def source_problem
        unless @sources.is_a?(Array) && @sources.size.between?(1, MAX_SOURCES)
          return "sources must be an array of 1 to #{MAX_SOURCES} urls"
        end

        "every source must be an http or https url of at most #{MAX_URL} characters" unless @sources.all? { |source| valid_url?(source) }
      end

      def valid_url?(source)
        return false unless source.is_a?(String) && source.length <= MAX_URL

        uri = URI.parse(source)
        uri.is_a?(URI::HTTP) && uri.host.present?
      rescue URI::InvalidURIError
        false
      end

      def success(row) = Result.new(success?: true, data: {request: row}, errors: [])

      def failure(code, detail) = Result.new(success?: false, data: nil, errors: [{code: code, detail: detail}])
    end
  end
end
