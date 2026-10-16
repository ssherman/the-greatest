# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class QueryIdentifiersTest < ActiveSupport::TestCase
          test "stamps each query identifier once, even when the book already holds one" do
            book = books_books(:war_and_peace)
            query = ImportQuery.new(title: "War and Peace", isbn13: [identifiers(:war_and_peace_isbn13).value],
              goodreads_id: ["656"])

            result = QueryIdentifiers.new.populate(book, query: query)
            book.save!

            assert result.success?
            assert_equal ["books_work_goodreads_id"], result.data_populated
            assert_equal 1, book.identifiers.where(identifier_type: :books_work_isbn13).count
            assert book.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "656")
          end

          test "stamped identifiers carry the source it was built with, and a held one keeps its own" do
            book = books_books(:war_and_peace)
            query = ImportQuery.new(title: "War and Peace", isbn13: [identifiers(:war_and_peace_isbn13).value],
              goodreads_id: ["656"])

            QueryIdentifiers.new(source: :amazon).populate(book, query: query)
            book.save!

            assert book.identifiers.find_by!(identifier_type: :books_work_goodreads_id, value: "656").source_amazon?
            assert_nil identifiers(:war_and_peace_isbn13).reload.source
          end

          test "the default source is goodreads_import" do
            book = ::Books::Book.new(title: "Stamped")

            QueryIdentifiers.new.populate(book, query: ImportQuery.new(title: "Stamped", goodreads_id: ["656"]))

            assert book.identifiers.first.source_goodreads_import?
          end

          test "no query, nothing stamped" do
            assert_equal [], QueryIdentifiers.new.populate(books_books(:war_and_peace), query: nil).data_populated
          end
        end
      end
    end
  end
end
