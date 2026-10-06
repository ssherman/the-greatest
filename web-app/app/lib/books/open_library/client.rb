# frozen_string_literal: true

module Books
  module OpenLibrary
    # Typed wrapper over BaseClient: every call returns a value object
    # (Work, Author, Edition, ShelfEntry, IdentifierHit, Resolution) rather
    # than the raw parsed-JSON Hash, so a caller can't silently come to
    # depend on a JSON key name that moves under it.
    class Client
      MAX_BATCH = 500
      IDENTIFIER_TYPES = %w[isbn13 isbn10 oclc lccn asin goodreads].freeze
      # A busy /resolve is retried only while at least this much of
      # config.resolve_timeout is left: one resolve takes 12-13 s on the home
      # server (docs/features/home-server.md).
      RESOLVE_MIN_ATTEMPT = 20
      # Used when a busy reply carries no Retry-After.
      DEFAULT_BUSY_WAIT = 2.0

      attr_reader :config, :base_client

      # `clock` and `sleeper` exist for tests: a busy /resolve waits, and a
      # test should not.
      def initialize(config: nil, breaker: nil, base_client: nil,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) })
        @config = config || Configuration.new
        @base_client = base_client || BaseClient.new(@config, breaker: breaker)
        @clock = clock
        @sleeper = sleeper
      end

      def work(key)
        Work.from_response(get("/works/#{key}"))
      end

      def editions(key)
        (get("/works/#{key}/editions")["data"] || []).map { |record| Edition.from_record(record) }
      end

      def author(key)
        Author.from_response(get("/authors/#{key}"))
      end

      def author_works(key, limit: 50, offset: 0)
        (get("/authors/#{key}/works", limit: limit, offset: offset)["data"] || [])
          .map { |record| ShelfEntry.from_record(record) }
      end

      # `type` is checked before any request goes out: an invalid type would
      # 422 anyway, but this way a typo never counts as a failure against
      # the circuit breaker.
      def identifier(type, value)
        unless IDENTIFIER_TYPES.include?(type.to_s)
          raise ArgumentError, "invalid identifier type: #{type.inspect}"
        end

        (get("/identifiers/#{type}/#{value}")["data"] || []).map { |record| IdentifierHit.from_record(record) }
      end

      # The service counts raw keys against MAX_BATCH before dedup, so this
      # checks the same way rather than deduping first and quietly letting a
      # too-large request through.
      def works_batch(keys)
        raise ArgumentError, "at most #{MAX_BATCH} keys, got #{keys.size}" if keys.size > MAX_BATCH

        envelope = post("/works/batch", {keys: keys})
        envelope["data"].transform_values do |record|
          record && Work.from_record(record, source_version: envelope["source_version"])
        end
      end

      def authors_batch(keys)
        raise ArgumentError, "at most #{MAX_BATCH} keys, got #{keys.size}" if keys.size > MAX_BATCH

        envelope = post("/authors/batch", {keys: keys})
        envelope["data"].transform_values do |record|
          record && Author.from_record(record, source_version: envelope["source_version"])
        end
      end

      # Body fields are allow-listed to exactly what the service's
      # ResolveRequest accepts (`extra="forbid"` server-side -- anything
      # else is a 422); optionals are omitted rather than sent nil/empty so
      # the service's own defaults apply instead of an explicit null.
      def resolve(title:, subtitle: nil, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [],
        goodreads_id: [], existing_ol_key: nil, description: nil, subjects: [], limit: nil)
        body = {title: title.to_s}
        body[:subtitle] = subtitle if subtitle.present?
        body[:author_names] = author_names if author_names.present?
        body[:year] = year if year.present?
        body[:isbn13] = isbn13 if isbn13.present?
        body[:isbn10] = isbn10 if isbn10.present?
        body[:asin] = asin if asin.present?
        body[:goodreads_id] = goodreads_id if goodreads_id.present?
        body[:existing_ol_key] = existing_ol_key if existing_ol_key.present?
        body[:description] = description if description.present?
        body[:subjects] = subjects if subjects.present?
        body[:limit] = limit if limit.present?

        Resolution.from_response(post_resolve(body))
      end

      # The one unenveloped response -- read by humans/ops, not parsed
      # elsewhere in this client -- so a plain symbol-keyed Hash is enough.
      def version
        get("/version").deep_symbolize_keys
      end

      private

      def get(path, params = {})
        base_client.get(path, params)[:data]
      end

      def post(path, body, timeout: nil)
        base_client.post(path, body, timeout: timeout)[:data]
      end

      # The service runs a fixed number of resolves at once and answers the
      # rest with an immediate 503 busy. Waiting that out here keeps a second
      # caller (another import, the duplicate sweep) from failing the source,
      # which the finder would record as a flagged row nothing retries. The
      # whole wait, attempts included, stays inside config.resolve_timeout;
      # each attempt gets whatever is left of it. The Retry-After wait is
      # stretched by up to half again so waiting callers do not retry in step.
      def post_resolve(body)
        started = @clock.call
        timeout = config.resolve_timeout
        loop do
          return post("/resolve", body, timeout: timeout)
        rescue Exceptions::BusyError => e
          wait = (e.retry_after || DEFAULT_BUSY_WAIT) * (1 + rand * 0.5)
          remaining = config.resolve_timeout - (@clock.call - started) - wait
          raise if remaining < RESOLVE_MIN_ATTEMPT

          @sleeper.call(wait)
          timeout = remaining
        end
      end
    end
  end
end
