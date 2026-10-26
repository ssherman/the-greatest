require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class PageCheckTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Catch-22")
          @book.authors << ::Books::Author.create!(name: "Joseph Heller")
        end

        def main_page(**overrides)
          html = Zlib.gunzip(file_fixture("goodreads/pages/catch_22_main_168668.html.gz").binread).force_encoding(Encoding::UTF_8)
          facts = ::Books::Goodreads::BookPage.parse(html: html, status: 200).facts
          ::Books::GoodreadsPage.new({
            goodreads_book_id: 168668, title: facts.title, genres: facts.genres,
            series: facts.series.map { |s| {"goodreads_series_id" => s.goodreads_series_id, "title" => s.title, "position" => s.position} },
            authors: facts.contributors.map { |c| {"name" => c.name, "role" => c.role, "primary" => c.primary} }
          }.merge(overrides))
        end

        test "the Catch-22 main edition page passes" do
          verdict = PageCheck.call(book: @book, page: main_page)

          assert_equal [true, nil], [verdict.ok, verdict.reason]
        end

        test "a sequel by the same author is a title_mismatch" do
          dune = ::Books::Book.create!(title: "Dune")
          dune.authors << ::Books::Author.create!(name: "Frank Herbert")
          page = main_page(title: "Dune Messiah", authors: [{"name" => "Frank Herbert", "role" => "Author", "primary" => true}])

          assert_equal "title_mismatch", PageCheck.call(book: dune, page: page).reason
        end

        test "a subtitle on the page's side still agrees" do
          sapiens = ::Books::Book.create!(title: "Sapiens")
          sapiens.authors << ::Books::Author.create!(name: "Yuval Noah Harari")
          page = main_page(title: "Sapiens: A Brief History of Humankind", authors: [{"name" => "Yuval Noah Harari", "role" => "Author", "primary" => true}])
          verdict = PageCheck.call(book: sapiens, page: page)

          assert_equal [true, nil], [verdict.ok, verdict.reason]
        end

        test "an alternate title of ours agrees" do
          @book.update!(alternate_titles: ["Catch 22: A Novel of War"])
          verdict = PageCheck.call(book: @book, page: main_page(title: "Catch 22: A Novel of War"))

          assert_equal [true, nil], [verdict.ok, verdict.reason]
        end

        test "another author is an author_mismatch" do
          page = main_page(authors: [{"name" => "Someone Else", "role" => "Author", "primary" => true}])

          assert_equal "author_mismatch", PageCheck.call(book: @book, page: page).reason
        end

        test "another title is a title_mismatch" do
          assert_equal "title_mismatch", PageCheck.call(book: @book, page: main_page(title: "Closing Time")).reason
        end

        test "an adaptation title is derivative" do
          assert_equal "derivative", PageCheck.call(book: @book, page: main_page(title: "Catch-22: The Graphic Novel")).reason
        end

        test "a Study Guides genre is a study_aid" do
          assert_equal "study_aid", PageCheck.call(book: @book, page: main_page(genres: ["Fiction", "Study Guides"])).reason
        end

        test "a ranged series position is a set" do
          page = main_page(series: [{"goodreads_series_id" => 1, "title" => "Catch-22", "position" => "1-3"}])

          assert_equal "set", PageCheck.call(book: @book, page: page).reason
        end

        test "a title carrying set words is rejected (the strict title check catches it first)" do
          assert_equal "title_mismatch", PageCheck.call(book: @book, page: main_page(title: "Catch-22 Omnibus")).reason
        end
      end
    end
  end
end
