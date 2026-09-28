# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      module Providers
        class EnrichmentTest < ActiveSupport::TestCase
          test "queues the Wikidata step for the author and reports it" do
            author = books_authors(:king)
            ::Books::Authors::WikidataJob.expects(:perform_async).with(author.id)

            result = Enrichment.new.populate(author, query: nil)

            assert result.success?
            assert_equal [:author_enrichment_queued], result.data_populated
          end

          test "fails for an author that is not saved" do
            ::Books::Authors::WikidataJob.expects(:perform_async).never

            result = Enrichment.new.populate(::Books::Author.new(name: "Unsaved"), query: nil)

            assert_not result.success?
            assert_includes result.errors, "Author must be persisted before queuing enrichment"
          end

          test "reports a queueing error as a failure" do
            ::Books::Authors::WikidataJob.stubs(:perform_async).raises(RedisClient::CannotConnectError)

            result = Enrichment.new.populate(books_authors(:king), query: nil)

            assert_not result.success?
            assert_match(/Author enrichment provider error/, result.errors.first)
          end
        end
      end
    end
  end
end
