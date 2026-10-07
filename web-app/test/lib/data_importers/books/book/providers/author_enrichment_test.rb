# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class AuthorEnrichmentTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
            @tolstoy = books_authors(:tolstoy)
            @king = books_authors(:king)
          end

          test "queues the Wikidata step once for each author the import created" do
            ::Books::Authors::WikidataJob.expects(:perform_async).with(@tolstoy.id).once
            ::Books::Authors::WikidataJob.expects(:perform_async).with(@king.id).once

            result = AuthorEnrichment.new(new_author_ids: [@tolstoy.id, @king.id, @tolstoy.id]).populate(@book, query: nil)

            assert result.success?
            assert_equal [:author_enrichment_queued], result.data_populated
          end

          test "an import that created no author queues nothing" do
            ::Books::Authors::WikidataJob.expects(:perform_async).never

            result = AuthorEnrichment.new.populate(@book, query: nil)

            assert result.success?
            assert_equal [], result.data_populated
          end

          test "turns an enqueue error into a failure result" do
            ::Books::Authors::WikidataJob.stubs(:perform_async).raises(RedisClient::CannotConnectError, "down")

            result = AuthorEnrichment.new(new_author_ids: [@tolstoy.id]).populate(@book, query: nil)

            refute result.success?
            assert_includes result.errors.first, "Author enrichment provider error"
          end

          test "the Wikidata step is queued only after the surrounding transaction commits, never on rollback" do
            provider = AuthorEnrichment.new(new_author_ids: [@tolstoy.id])
            ::Sidekiq::Testing.fake! do
              ::Books::Authors::WikidataJob.clear
              ::ActiveRecord::Base.transaction(requires_new: true) do
                provider.populate(@book, query: nil)
                assert_empty ::Books::Authors::WikidataJob.jobs
              end
              assert_equal 1, ::Books::Authors::WikidataJob.jobs.size

              ::Books::Authors::WikidataJob.clear
              ::ActiveRecord::Base.transaction(requires_new: true) do
                provider.populate(@book, query: nil)
                raise ::ActiveRecord::Rollback
              end
              assert_empty ::Books::Authors::WikidataJob.jobs
            end
          end
        end
      end
    end
  end
end
