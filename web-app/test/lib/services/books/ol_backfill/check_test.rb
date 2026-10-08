# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class CheckTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # Leo Tolstoy; alternate title "Voyna i mir"
        end

        test "agrees on equal titles and a shared author" do
          assert Check.agree?(@book, ol_work("OL1W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]]))
        end

        test "a matching title with no shared author does not agree" do
          assert_not Check.agree?(@book, ol_work("OL1W", title: "War and Peace", authors: [["OL2A", "Somebody Else"]]))
        end

        test "titles agree once a subtitle is dropped from one side" do
          assert Check.titles_agree?(@book, ol_work("OL1W", title: "War and Peace: A Novel"))
          assert Check.titles_agree?(@book, ol_work("OL1W", title: "War and Peace", subtitle: "A Novel"))
          @book.title = "War and Peace: The Maude Translation"
          assert Check.titles_agree?(@book, ol_work("OL1W", title: "War and Peace"))
        end

        test "titles never agree on two different subtitles of the same head" do
          @book.title = "Dune: Messiah"
          assert_not Check.titles_agree?(@book, ol_work("OL1W", title: "Dune: Part One"))
          assert_not Check.titles_agree?(@book, ol_work("OL1W", title: "Dune", subtitle: "Part One"))
        end

        test "an alternate title agrees, a different title does not" do
          assert Check.titles_agree?(@book, ol_work("OL1W", title: "Voyna i mir"))
          assert_not Check.titles_agree?(@book, ol_work("OL1W", title: "Anna Karenina"))
        end

        test "authors agree on a name or an alternate name, ignoring case and spacing" do
          assert Check.authors_agree?(@book, ol_work("OL1W", title: "x", authors: [["OL1A", "leo  TOLSTOY"]]))
          books_authors(:tolstoy).update!(alternate_names: ["Lev Tolstoy"])
          assert Check.authors_agree?(@book.reload, ol_work("OL1W", title: "x", authors: [["OL1A", "Lev Tolstoy"]]))
        end

        test "a book with no authors never agrees" do
          book = books_books(:crime_and_punishment)
          assert_empty book.authors
          assert_not Check.agree?(book, ol_work("OL1W", title: "Crime and Punishment", authors: [["OL1A", "Fyodor Dostoevsky"]]))
        end

        test "a work with no title never agrees" do
          assert_not Check.titles_agree?(@book, ol_work("OL1W", title: nil))
        end
      end
    end
  end
end
