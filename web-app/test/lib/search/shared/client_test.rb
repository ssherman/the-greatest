# frozen_string_literal: true

require "test_helper"

module Search
  module Shared
    class ClientTest < ActiveSupport::TestCase
      setup do
        @original_api_serializer = OpenSearch::API.settings[:serializer]
      end

      teardown do
        OpenSearch::API.settings[:serializer] = @original_api_serializer
        Search::Shared::Client.reset!
      end

      test "instance configures OpenSearch::API's module-level bulk serializer" do
        # client.bulk (bulk_index/bulk_unindex/bulk_update/reindex_all) never touches
        # the client's serializer_class -- opensearch-ruby's __bulkify reads this
        # separate, process-global setting instead (see Search::Shared::Client).
        # Force a fresh build so this proves `instance` sets it, rather than just
        # observing a value some earlier test happened to leave behind.
        OpenSearch::API.settings[:serializer] = nil
        Search::Shared::Client.reset!

        Search::Shared::Client.instance

        assert_instance_of Search::Shared::Serializer, OpenSearch::API.serializer
      end

      test "instance skips certificate verification when OPENSEARCH_SSL_VERIFY is false" do
        with_env("OPENSEARCH_SSL_VERIFY" => "false") do
          Search::Shared::Client.reset!

          refute ssl_options.verify?
        end
      end

      test "instance verifies certificates when OPENSEARCH_SSL_VERIFY is unset" do
        with_env("OPENSEARCH_SSL_VERIFY" => nil) do
          Search::Shared::Client.reset!

          assert ssl_options.verify?
        end
      end

      test "instance verifies certificates for any value other than false" do
        with_env("OPENSEARCH_SSL_VERIFY" => "no") do
          Search::Shared::Client.reset!

          assert ssl_options.verify?
        end
      end

      private

      # opensearch-ruby 3.4: Client -> Transport::Client -> HTTP::Faraday -> Connection -> Faraday::Connection.
      def ssl_options
        Search::Shared::Client.instance.transport.transport.connections.first.connection.ssl
      end
    end
  end
end
