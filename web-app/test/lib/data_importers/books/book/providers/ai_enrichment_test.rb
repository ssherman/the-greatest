# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class AiEnrichmentTest < ActiveSupport::TestCase
          def setup
            @provider = AiEnrichment.new
            @book = books_books(:war_and_peace)
            @query = ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"])
          end

          test "queues the job with the book's own authors and reports success" do
            ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false, ["Leo Tolstoy"])

            result = @provider.populate(@book, query: @query)

            assert result.success?
            assert_equal [:ai_enrichment_queued], result.data_populated
          end

          test "falls back to the query's author names when the book has none" do
            book = ::Books::Book.create!(title: "Brand New")
            query = ImportQuery.new(title: "Brand New", author_names: ["Someone New"])
            ::Books::EnrichBookJob.expects(:perform_async).with(book.id, false, ["Someone New"])

            result = @provider.populate(book, query: query)

            assert result.success?
          end

          test "fails without a title" do
            @book.title = ""
            ::Books::EnrichBookJob.expects(:perform_async).never

            result = @provider.populate(@book, query: @query)

            refute result.success?
            assert_includes result.errors, "Book title required for AI enrichment"
          end

          test "fails when neither the book nor the query has authors" do
            book = ::Books::Book.create!(title: "Nobody's Book")
            ::Books::EnrichBookJob.expects(:perform_async).never

            result = @provider.populate(book, query: ImportQuery.new(title: "Nobody's Book"))

            refute result.success?
            assert_includes result.errors, "Book must have an author for AI enrichment"
          end

          test "fails when the book is not persisted" do
            book = ::Books::Book.new(title: "Unsaved")
            ::Books::EnrichBookJob.expects(:perform_async).never

            result = @provider.populate(book, query: @query)

            refute result.success?
            assert_includes result.errors, "Book must be persisted before queuing AI enrichment"
          end

          test "works with a nil query for item-based imports" do
            ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false, ["Leo Tolstoy"])

            assert @provider.populate(@book, query: nil).success?
          end

          test "turns an enqueue error into a failure result" do
            ::Books::EnrichBookJob.stubs(:perform_async).raises(Redis::CannotConnectError, "down")

            result = @provider.populate(@book, query: @query)

            refute result.success?
            assert_match(/AI enrichment provider error: down/, result.errors.first)
          end
        end
      end
    end
  end
end
