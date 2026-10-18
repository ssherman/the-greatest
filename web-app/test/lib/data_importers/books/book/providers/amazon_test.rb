# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class AmazonTest < ActiveSupport::TestCase
          test "queues the Amazon job for a persisted book with an author" do
            book = books_books(:war_and_peace)
            ::Books::AmazonProductEnrichmentJob.expects(:perform_async).with(book.id)
            result = Amazon.new.populate(book, query: nil)
            assert result.success?
            assert_equal [:amazon_enrichment_queued], result.data_populated
          end

          test "queues nothing when the surrounding transaction rolls back" do
            ::Books::AmazonProductEnrichmentJob.expects(:perform_async).never
            ActiveRecord::Base.transaction(requires_new: true) do
              book = ::Books::Book.create!(title: "Rolled Back")
              book.book_authors.create!(author: books_authors(:tolstoy), position: 1)
              Amazon.new.populate(book, query: nil)
              raise ActiveRecord::Rollback
            end
          end

          test "fails without a title, without an author, or unsaved, and queues nothing" do
            ::Books::AmazonProductEnrichmentJob.expects(:perform_async).never
            assert_includes Amazon.new.populate(::Books::Book.new(title: ""), query: nil).errors, "Book title required for Amazon enrichment"
            assert_includes Amazon.new.populate(::Books::Book.create!(title: "No Author"), query: nil).errors, "Book must have an author for Amazon enrichment"
            unsaved = ::Books::Book.new(title: "Unsaved")
            unsaved.stubs(:authors).returns([books_authors(:tolstoy)])
            assert_includes Amazon.new.populate(unsaved, query: nil).errors, "Book must be persisted before queuing Amazon enrichment"
          end
        end
      end
    end
  end
end
