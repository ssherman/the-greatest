# frozen_string_literal: true

module Viaf
  module Search
    # SRU/CQL search, for when AutoSuggest does not resolve a name.
    #
    # Much more expensive than AutoSuggest: a 3-record search is ~136 KB against
    # AutoSuggest's 3 KB for ten candidates. Prefer AutoSuggest.
    #
    # Results are NOT cached in external_records. Search returns whole clusters,
    # but the viafID in the body is the only ID available and VIAF has been seen
    # emitting it in lossy scientific notation, so there is no trustworthy cache
    # key. Fetch the chosen ID through Viaf::Cluster to cache it.
    class PersonSearch
      ENDPOINT = "viaf/search"
      DEFAULT_LIMIT = 10

      def initialize(client = nil)
        @client = client || BaseClient.new
      end

      def call(name, limit: DEFAULT_LIMIT)
        raise ArgumentError, "name cannot be blank" if name.blank?

        response = @client.get(ENDPOINT, {
          query: %(local.personalNames all "#{escape(name)}"),
          maximumRecords: limit,
          sortKey: "holdingscount"
        })

        records(response[:data]).filter_map { |record| person_from(record) }
      end

      private

      # Block form: gsub's replacement string treats backslashes as escapes,
      # so a literal '\\"' replacement is ambiguous.
      def escape(name) = name.gsub('"') { '\\"' }

      def records(data)
        Normalizer.array(data.dig("searchRetrieveResponse", "records", "record"))
      end

      def person_from(record)
        cluster = record["recordData"]
        return nil if cluster.nil?

        normalized = Normalizer.call(cluster)
        viaf_id = normalized.dig("VIAFCluster", "viafID")
        return nil if viaf_id.nil?

        payload = Distiller.call(cluster, requested_id: viaf_id.to_s)
        Person.from_payload(payload)
      rescue Exceptions::Error
        nil
      end
    end
  end
end
