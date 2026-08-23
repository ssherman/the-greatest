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
    end
  end
end
