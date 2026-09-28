# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class AuthorsTest < ActiveSupport::TestCase
          IMPORTER = ::DataImporters::Books::Author::Importer

          def setup
            @provider = Providers::Authors.new
            @tolstoy = books_authors(:tolstoy)
            @king = books_authors(:king)
            # Sidekiq runs inline in tests; a real author import would
            # enqueue the Wikidata step.
            ::Books::Authors::WikidataJob.stubs(:perform_async)
          end

          def result_for(author)
            DataImporters::ImportResult.new(item: author, provider_results: [], success: true)
          end

          def query(names)
            DataImporters::Books::Book::ImportQuery.new(title: "Hadji Murat", author_names: names)
          end

          test "imports each query name by name and links the authors in the query's order" do
            book = ::Books::Book.new(title: "Hadji Murat")
            IMPORTER.expects(:call).with(name: "Stephen King", work_titles: ["Hadji Murat"]).returns(result_for(@king))
            IMPORTER.expects(:call).with(name: "Leo Tolstoy", work_titles: ["Hadji Murat"]).returns(result_for(@tolstoy))

            result = @provider.populate(book, query: query(["Stephen King", "Leo Tolstoy"]))

            assert result.success?
            assert_equal [:authors], result.data_populated
            assert_equal [[@king, 1], [@tolstoy, 2]], book.book_authors.map { |link| [link.author, link.position] }
          end

          test "two names resolving to the same author make one link" do
            book = ::Books::Book.new(title: "Hadji Murat")
            IMPORTER.stubs(:call).returns(result_for(@tolstoy))

            @provider.populate(book, query: query(["Leo Tolstoy", "Lev Tolstoy"]))

            assert_equal [@tolstoy], book.book_authors.map(&:author)
          end

          test "a book with no title never reaches the author importer, and fails" do
            IMPORTER.expects(:call).never

            result = @provider.populate(::Books::Book.new(title: nil), query: query(["Zed Orphanmaker"]))

            assert_not result.success?
          end

          test "a book that already has authors is left alone" do
            book = books_books(:war_and_peace)
            IMPORTER.expects(:call).never

            result = @provider.populate(book, query: query(["Stephen King"]))

            assert result.success?
            assert_equal [], result.data_populated
          end

          test "no names is a failure" do
            IMPORTER.expects(:call).never

            assert_not @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: query([])).success?
            assert_not @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: nil).success?
          end

          test "an author the importer could not persist is skipped; none at all is a failure" do
            IMPORTER.stubs(:call).returns(result_for(::Books::Author.new))

            result = @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: query(["???"]))

            assert_not result.success?
          end

          test "an error inside the author importer is a failure result" do
            IMPORTER.stubs(:call).raises(StandardError, "boom")

            result = @provider.populate(::Books::Book.new(title: "Hadji Murat"), query: query(["Leo Tolstoy"]))

            assert_not result.success?
            assert_match(/boom/, result.errors.first)
          end
        end
      end
    end
  end
end
