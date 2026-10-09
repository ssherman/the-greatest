# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class AuthorKeysTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace)
          @tolstoy = books_authors(:tolstoy)
          @work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
        end

        def author_keys(author)
          author.identifiers.where(identifier_type: :books_author_openlibrary_id).pluck(:value)
        end

        test "an author with no key takes the matched work author's key" do
          changes = AuthorKeys.call(book: @book, work: @work)

          assert_equal [["OL26783A"], [[@tolstoy.id, "OL26783A"]]], [author_keys(@tolstoy), changes["added"]]
        end

        test "an author already holding that key is left alone" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")

          assert_equal({"added" => [], "pairs" => [], "conflicts" => []}, AuthorKeys.call(book: @book, work: @work))
        end

        test "an author holding a different key is a conflict and keeps its key" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL9A")

          changes = AuthorKeys.call(book: @book, work: @work)

          assert_equal [["OL9A"], [[@tolstoy.id, "OL9A", "OL26783A"]]], [author_keys(@tolstoy), changes["conflicts"]]
        end

        test "another author holding the key is a flagged pair, and no key is saved" do
          king = books_authors(:king)
          king.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")

          changes = AuthorKeys.call(book: @book, work: @work)

          assert_empty author_keys(@tolstoy)
          assert_equal [[@tolstoy.id, king.id, "OL26783A"]], changes["pairs"]
          pair = ::DuplicateCandidate.find_by(item_type: "Books::Author", item_a_id: [@tolstoy.id, king.id].min, item_b_id: [@tolstoy.id, king.id].max)
          assert_equal "ol_backfill", pair.source
        end

        test "an alternate name pairs an author" do
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Lev Tolstoy"]])

          assert_equal [[@tolstoy.id, "OL26783A"]], AuthorKeys.call(book: @book.reload, work: work)["added"]
        end

        test "no work author with the name, or two with different keys, leaves the author alone" do
          nobody = ol_work("OL1W", title: "War and Peace", authors: [["OL5A", "Somebody Else"]])
          twins = ol_work("OL1W", title: "War and Peace", authors: [["OL5A", "Leo Tolstoy"], ["OL6A", "Leo Tolstoy"]])

          assert_empty AuthorKeys.call(book: @book, work: nobody)["added"]
          assert_empty AuthorKeys.call(book: @book, work: twins)["added"]
          assert_empty author_keys(@tolstoy)
        end
      end
    end
  end
end
