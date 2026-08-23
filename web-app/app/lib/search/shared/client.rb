# frozen_string_literal: true

module Search
  module Shared
    class Client
      class << self
        def instance
          @instance ||= begin
            configure_bulk_serializer!

            OpenSearch::Client.new(
              host: ENV.fetch("OPENSEARCH_URL"),
              serializer_class: Search::Shared::Serializer
            )
          end
        end

        def reset!
          @instance = nil
        end

        def health
          instance.cluster.health
        end

        def cluster_info
          instance.info
        end

        def ping
          instance.ping
        rescue
          false
        end

        private

        # `bulk` doesn't serialize through this client at all: opensearch-ruby's
        # __bulkify builds the NDJSON body via the *module-level*
        # OpenSearch::API.serializer setting before the request ever reaches the
        # transport, so the client's serializer_class: above has no effect on it.
        # Both knobs have to point at the non-deprecated serializer, or bulk calls
        # (reindexing, bulk_update, ...) keep warning on their own.
        def configure_bulk_serializer!
          OpenSearch::API.settings[:serializer] = Search::Shared::Serializer.new
        end
      end
    end
  end
end
