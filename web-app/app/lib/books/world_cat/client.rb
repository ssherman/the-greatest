# frozen_string_literal: true

module Books
  module WorldCat
    # Typed client for the WorldCat lookup service (docs/features/worldcat-data-service.md).
    # Exact lookups only; every method returns value objects or nil, never raw JSON.
    class Client
      MAX_BATCH = 500

      attr_reader :config, :base_client

      def initialize(config: nil, breaker: nil, base_client: nil)
        @config = config || Configuration.new
        @base_client = base_client || BaseClient.new(@config, breaker: breaker)
      end

      # @return [Array<Record>] empty when the service has no record for the ISBN
      def record_by_isbn(isbn)
        (get("/isbns/#{isbn}")["records"] || []).map { |hash| Record.from_hash(hash) }
      end

      # @return [Record, nil] nil when the number is unknown (a 404 is an answer, not a failure)
      def record_by_oclc(number)
        Record.from_hash(get("/oclc/#{number}"))
      rescue Exceptions::NotFoundError
        nil
      end

      # @return [Hash{String => Array<Record>}] one key per ISBN given, as given
      def lookup(isbn13s)
        isbn13s.each_slice(MAX_BATCH).each_with_object({}) do |slice, out|
          results = post("/lookup", {isbn13s: slice}, timeout: config.batch_timeout)["results"] || {}
          slice.each { |isbn| out[isbn] = (results[isbn] || []).map { |hash| Record.from_hash(hash) } }
        end
      end

      def version
        get("/version").deep_symbolize_keys
      end

      private

      def get(path)
        base_client.get(path)[:data]
      end

      def post(path, body, timeout:)
        base_client.post(path, body, timeout: timeout)[:data]
      end
    end
  end
end
