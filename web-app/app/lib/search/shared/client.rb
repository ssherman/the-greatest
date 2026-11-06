# frozen_string_literal: true

module Search
  module Shared
    class Client
      # opensearch-ruby raises this exact class, with no HTTP status, when every
      # connection in its pool is dead ("Cannot get new connection from pool").
      # It is also the superclass of every HTTP-status error, including the 4xx
      # ones, so it cannot go in a class list as it is: `===` here matches only an
      # instance of exactly that class, and a BadRequest is not one. A Module with
      # its own `===` is accepted anywhere a class is: `rescue_from` and `rescue`.
      module ConnectionPoolExhausted
        def self.===(error) = error.instance_of?(::OpenSearch::Transport::Transport::Error)
      end

      # What a search call raises when OpenSearch cannot answer, and a retry might
      # succeed: a failure to reach the cluster, a timeout, or a 5xx / 429 from it.
      # The public API turns these into a 503. A 4xx from the cluster (a BadRequest
      # for a query it will not run, say) is deliberately absent: that is our bug,
      # and it should surface as a 500 that error tracking sees, not as an outage
      # a client would retry forever.
      UNAVAILABLE_ERRORS = [
        ::Faraday::Error,
        ::Timeout::Error,
        ::OpenSearch::Transport::Transport::Errors::InternalServerError,
        ::OpenSearch::Transport::Transport::Errors::BadGateway,
        ::OpenSearch::Transport::Transport::Errors::ServiceUnavailable,
        ::OpenSearch::Transport::Transport::Errors::GatewayTimeout,
        ::OpenSearch::Transport::Transport::Errors::TooManyRequests,
        ConnectionPoolExhausted
      ].freeze

      class << self
        def instance
          @instance ||= begin
            configure_bulk_serializer!

            OpenSearch::Client.new(
              host: ENV.fetch("OPENSEARCH_URL"),
              serializer_class: Search::Shared::Serializer,
              transport_options: transport_options
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

        # The production search server presents a certificate it generated for itself
        # (docs/features/opensearch-server.md), so there is no CA to check it against. The
        # firewall and the per-app login keep others out; TLS here only stops eavesdropping.
        def transport_options
          return {} unless ENV["OPENSEARCH_SSL_VERIFY"] == "false"

          {ssl: {verify: false}}
        end

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
