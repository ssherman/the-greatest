# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class EditionCheckTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace)
          @book.update_columns(first_published_year: 1869, alternate_titles: [])
          @work = ol_work("OL1W", title: "War and Peace")
        end

        def agrees?(title, subtitle: nil, year: nil) = EditionCheck.agrees?(@book, @work, ol_edition("OL1M", title: title, subtitle: subtitle, publish_year: year))

        test "an edition with the book's title agrees" do
          assert agrees?("War and Peace", year: 2007)
          assert agrees?("war and peace")
        end

        test "an edition whose subtitle is ordinary agrees once it is dropped" do
          assert agrees?("War and Peace", subtitle: "A Novel")
          assert agrees?("War and Peace: Complete and Unabridged")
        end

        test "an edition whose dropped subtitle names a set does not agree" do
          refute agrees?("War and Peace", subtitle: "Box Set")
          refute agrees?("War and Peace: The Boxed Set")
          refute agrees?("War and Peace", subtitle: "Volumes 1-4")
          refute agrees?("War and Peace: An Omnibus")
        end

        test "a translation or another title does not agree" do
          refute agrees?("Krieg und Frieden")
          refute agrees?("Anna Karenina")
        end

        test "the work's own title counts as one of ours" do
          @book.update_columns(title: "War & Peace")

          assert agrees?("War and Peace")
        end

        test "an edition dated before the book's first publication does not agree; one year of slack" do
          refute agrees?("War and Peace", year: 1850)
          assert agrees?("War and Peace", year: 1868)
        end

        test "with a subtitled work, an edition equal to the work without its subtitle agrees" do
          work = ol_work("OL1W", title: "War and Peace", subtitle: "A Novel")

          assert EditionCheck.agrees?(@book, work, ol_edition("OL1M", title: "War and Peace"))
          assert EditionCheck.agrees?(@book, work, ol_edition("OL1M", title: "War and Peace", subtitle: "Penguin Classics"))
        end

        test "a subtitle is never dropped from both sides" do
          work = ol_work("OL1W", title: "War and Peace", subtitle: "A Novel")
          @book.update_columns(title: "War and Peace: A Novel")

          refute EditionCheck.agrees?(@book, work, ol_edition("OL1M", title: "War and Peace", subtitle: "Graphic Edition"))
        end

        test "a different subtitle on an edition of a subtitled work does not agree" do
          @book.update_columns(title: "Sapiens: A Brief History of Humankind")
          work = ol_work("OL1W", title: "Sapiens", subtitle: "A Brief History of Humankind")

          refute EditionCheck.agrees?(@book, work, ol_edition("OL1M", title: "Sapiens", subtitle: "A Graphic History"))
          refute EditionCheck.agrees?(@book, work, ol_edition("OL1M", title: "Sapiens", subtitle: "Une breve histoire de l humanite"))
        end

        test "a book with no first-published year skips the year rule" do
          @book.update_columns(first_published_year: nil)

          assert agrees?("War and Peace", year: 1700)
        end
      end
    end
  end
end
