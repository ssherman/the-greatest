# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class WorldCatCheckTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # Leo Tolstoy
          @book.update_columns(first_published_year: 1869)
        end

        def record(**overrides) = wc_record(oclc: 1, title: "War and peace", creator: "Leo Tolstoy", year: 2007, **overrides)

        test "a record agreeing on title, creator and year agrees" do
          assert WorldCatCheck.agrees?(@book, record)
        end

        test "WorldCat's ' : ' subtitle form and lowercase are tolerated" do
          assert WorldCatCheck.agrees?(@book, record(title: "War and peace : a novel"))
        end

        test "a subtitle dropped from the record must not name a set" do
          refute WorldCatCheck.agrees?(@book, record(title: "War and peace : boxed set"))
          refute WorldCatCheck.agrees?(@book, record(title: "War and peace : collection, volumes 1-4"))
        end

        test "a garbled record of the right book is unknown, not clearly different" do
          book = ::Books::Book.create!(title: "Cré na Cille", first_published_year: 1949)
          book.book_authors.create!(author: ::Books::Author.create!(name: "Máirtín Ó Cadhain"))
          garbled = record(title: "Cr©Øe na cille", creator: "M©Øairt©Øin ©ØO Cadhain")

          refute WorldCatCheck.clearly_different?(book.reload, garbled)
        end

        test "an inverted creator with dates still matches" do
          assert WorldCatCheck.agrees?(@book, record(creator: "Tolstoy, Leo, 1828-1910."))
          assert WorldCatCheck.agrees?(@book, record(creator: nil, contributors: ["Tolstoy, Leo (Lev Nikolaevich)"]))
        end

        test "a garbled record never agrees" do
          refute WorldCatCheck.agrees?(@book, record(title: "War and peace", creator: "L©Øev Tol©Østoy"))
        end

        test "a placeholder title does not agree" do
          refute WorldCatCheck.agrees?(@book, record(title: "Untitled Leo Tolstoy novel"))
        end

        test "a record dated before the book does not agree" do
          refute WorldCatCheck.agrees?(@book, record(year: 1800))
        end

        test "clearly_different needs both title and creator to disagree" do
          assert WorldCatCheck.clearly_different?(@book, record(title: "Gloriana", creator: "Michael Moorcock"))
          refute WorldCatCheck.clearly_different?(@book, record(title: "Gloriana"))
          refute WorldCatCheck.clearly_different?(@book, record(creator: "Michael Moorcock"))
        end

        test "a record with no creator is unknown, not clearly different" do
          refute WorldCatCheck.clearly_different?(@book, record(title: "Gloriana", creator: nil))
        end

        test "a complete or collected edition of our title is not clearly different" do
          essays = ::Books::Book.create!(title: "Essays")
          essays.book_authors.create!(author: ::Books::Author.create!(name: "Michel de Montaigne"))
          proust = ::Books::Book.create!(title: "In Search of Lost Time")
          proust.book_authors.create!(author: ::Books::Author.create!(name: "Marcel Proust"))

          refute WorldCatCheck.clearly_different?(essays.reload, record(title: "Complete Essays / Montaigne Michel de", creator: "Montaigne Michel de"))
          refute WorldCatCheck.clearly_different?(proust.reload, record(title: "In Search of Lost Time (All 7 Volumes) / Proust Marcel", creator: "Proust Marcel"))
        end

        test "a different book with some shared words is still clearly different" do
          power = ::Books::Book.create!(title: "The Power and the Glory")
          power.book_authors.create!(author: ::Books::Author.create!(name: "Graham Greene"))

          assert WorldCatCheck.clearly_different?(power.reload, record(title: "The 48 laws of power / Robert Greene", creator: "Robert Greene"))
        end
      end
    end
  end
end
