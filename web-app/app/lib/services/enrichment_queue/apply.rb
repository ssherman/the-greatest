module Services
  module EnrichmentQueue
    # Applies a submitted answer by calling the type, from ApplyJob. A failed
    # apply raises Failed, so Sidekiq retries it and the row stays submitted;
    # when retries run out the job calls fail!.
    #
    # One apply attempt per request at a time. A stale submitted row can have two
    # jobs (Retry apply while the first still waits in the queue, or a Sidekiq
    # redelivery); unguarded, both would call the type, and the second, finding
    # the field filled, would overwrite the first's `applied` with
    # `nothing_to_apply`. So the attempt holds a Postgres advisory lock on the
    # request, keyed (namespace, request id). It is session-level, not transaction-level: the type's apply can
    # call a model over HTTP for seconds, and that must not sit in one long
    # transaction. A session lock is also released by Postgres if the worker dies,
    # so a crash cannot leave a request locked. One connection is pinned for the
    # whole attempt so the lock and the unlock are on the same session.
    #
    # The type may reach code (mergers, the ledger) that records who acted, so
    # Current carries the submitter's identity while it runs and is restored
    # afterwards, even if the type raises.
    class Apply
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      class Failed < StandardError; end

      MAX_ERROR = 1_000
      LOCK_NAMESPACE = "enrichment_request_apply"

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
        ::EnrichmentRequest.with_connection do |connection|
          # Set before the acquire: if that call raises after the server granted
          # the lock, the ensure must still release it. Only a plain `false`
          # (not granted) skips the release, since unlocking a lock this session
          # does not hold makes Postgres emit a WARNING.
          release = false
          begin
            release = true
            # Another worker is applying this request: its job finishes or retries.
            return noop unless (release = acquire_lock(connection))

            apply_locked
          ensure
            release_lock(connection) if release
          end
        end
      end

      private

      def apply_locked
        # Read after the lock, not before: a row another worker already closed
        # while this job waited is a no-op.
        request = ::EnrichmentRequest.find_by(id: @request_id)
        return noop unless request&.submitted?

        if request.enrichable.nil?
          request.delete
          return noop
        end

        result = with_acting(request) { Registry.fetch(request.kind).apply(request) }
        raise Failed, "apply failed for request #{request.id}: #{Array(result.errors).join("; ")}" unless result.success?

        # Guarded. Under the lock, the only thing that turns the row this job read
        # as submitted into failed is another chain's fail! (it does not take the
        # lock); the answer has been applied, so done wins over it. A re-queue to
        # pending still wins over this write.
        statuses = ::EnrichmentRequest.statuses
        closed = ::EnrichmentRequest.where(id: request.id, status: [statuses.fetch("submitted"), statuses.fetch("failed")])
          .update_all(status: statuses.fetch("done"), outcome: result.data[:outcome], error: nil,
            enrichment_id: result.data[:enrichment]&.id, lease_token: nil, lease_expires_at: nil, updated_at: Time.current)
        return noop if closed.zero?

        Result.new(success?: true, data: {request: request.reload}, errors: [])
      end

      def noop = Result.new(success?: true, data: nil, errors: [])

      # The only place that takes the lock (tests stub it). Uncached: inside the
      # Rails executor select_value is answered from the query cache, so a repeated
      # lock or unlock would never reach the server.
      def acquire_lock(connection) = lock_query(connection, "pg_try_advisory_lock")

      def unlock(connection) = lock_query(connection, "pg_advisory_unlock")

      # Never raises: it runs in an ensure and must not mask the apply's own error.
      def release_lock(connection)
        return if unlock(connection)

        ::Rails.logger.warn("EnrichmentQueue::Apply #{@request_id}: advisory lock was already lost")
      rescue => e
        ::Rails.logger.warn("EnrichmentQueue::Apply #{@request_id}: releasing the advisory lock failed: #{e.class}: #{e.message}")
        # The lock may still be on this live pooled session, where it would turn
        # every later apply of this request into a no-op. Dropping the session
        # makes Postgres free it; the adapter reconnects on next use.
        begin
          connection.disconnect!
        rescue
          nil
        end
      end

      # Two-key form: (namespace hash, request id). It is a lock space separate
      # from the one-key form the app's other advisory locks use, and the id is
      # not hashed, so two requests cannot collide.
      def lock_query(connection, function)
        connection.uncached do
          connection.select_value("SELECT #{function}(hashtext('#{LOCK_NAMESPACE}'), $1::integer)", "EnrichmentQueue::Apply lock", [@request_id])
        end
      end

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
