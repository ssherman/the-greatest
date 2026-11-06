# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class FixScopeTest < ActiveSupport::TestCase
        setup do
          @author = ::Books::Author.create!(name: "Some Author")
        end

        # export is "Title" or "Title: Subtitle" (optionally with series noise after the title, as Goodreads writes it).
        def scope(ours, export, subtitle: nil, authors_agree: true, wrong_book: false, survey: true, book_authors: [@author],
          export_authors: {"Some Author" => @author.id}, export_subtitle: :split)
          book = ::Books::Book.create!(title: ours, subtitle: subtitle)
          book_authors.each_with_index { |author, i| book.book_authors.create!(author: author, position: i + 1) }
          record = ::Books::RebuildBookSurvey.new(book: book, authors_agree: authors_agree, wrong_book: wrong_book) if survey
          head, sub = export.split(": ", 2)
          sub = nil if export_subtitle.nil?
          payload = {"full_title" => export, "title" => head, "subtitle" => sub, "author_names" => export_authors.keys, "author_links" => export_authors}
          FixScope.call(book: book.reload, survey: record, payload: payload)
        end

        test "series noise only is none" do
          assert_equal :none, scope("Euthydemus", "Euthydemus (Hackett Classics)")
        end

        test "our title and real subtitle against the export's title with series noise is none" do
          assert_equal :none, scope("The Red Indians", "The Red Indians (Semaphore)",
            subtitle: "An Episodic, Informal Collection of Essays on Indigenous Peoples in Canada")
        end

        test "our title and subtitle against the export's with series noise is none" do
          assert_equal :none, scope("X", "X: Y (Series)", subtitle: "Y")
        end

        test "ours with the real subtitle against an export of the bare title is none" do
          assert_equal :none, scope("X", "X", subtitle: "Y")
        end

        test "an export that matches our title and subtitle is none" do
          assert_equal :none, scope("Destination", "Destination: Void", subtitle: "Void")
        end

        test "a subtitle our title lacks is title_only" do
          assert_equal :title_only, scope("Destination", "Destination: Void")
          assert_equal :title_only, scope("Everything Must Go", "Everything Must Go: The Stories We Tell About the End of the World")
        end

        test "a title that extends or is extended by the other is full, since it may be another book" do
          assert_equal :full, scope("Dune Messiah", "Dune")
          assert_equal :full, scope("Dune", "Dune Messiah")
          assert_equal :full, scope("Harry Potter", "Harry Potter and the Chamber of Secrets")
          assert_equal :full, scope("Silo 1", "Silo")
          assert_equal :full, scope("The 33 Strategies Of War New Edition By Robert Greene Paperback", "The 33 Strategies of War")
        end

        test "a title that really differs is full" do
          assert_equal :full, scope("Ninguno de nosotros volverá", "Auschwitz and After")
          assert_equal :full, scope("Art", "Artificial Intelligence")
        end

        test "authors the survey says differ are full, however alike the titles" do
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", authors_agree: false)
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", authors_agree: nil)
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", wrong_book: true)
        end

        test "an extra co-author on the book is full" do
          other = ::Books::Author.create!(name: "Wrong Co-author")
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", book_authors: [@author, other])
        end

        test "an export co-author missing from the book is full" do
          other = ::Books::Author.create!(name: "Second Author")
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)",
            export_authors: {"Some Author" => @author.id, "Second Author" => other.id})
        end

        test "an export author with no link, or no author_links at all, is full" do
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", export_authors: {"Some Author" => nil})
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", export_authors: {})
        end

        test "the exact author set is as before, in any order" do
          other = ::Books::Author.create!(name: "Second Author")
          assert_equal :none, scope("Euthydemus", "Euthydemus (Hackett Classics)", book_authors: [other, @author],
            export_authors: {"Some Author" => @author.id, "Second Author" => other.id})
        end

        test "no survey is full" do
          assert_equal :full, scope("Euthydemus", "Euthydemus", survey: false)
        end
      end
    end
  end
end
