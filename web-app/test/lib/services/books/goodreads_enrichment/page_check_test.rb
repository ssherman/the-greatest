require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class PageCheckTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Catch-22")
          @book.authors << ::Books::Author.create!(name: "Joseph Heller")
        end

        def stray_page(**overrides)
          html = Zlib.gunzip(file_fixture("goodreads/pages/catch_22_stray_edition_147719920.html.gz").binread).force_encoding(Encoding::UTF_8)
          facts = ::Books::Goodreads::BookPage.parse(html: html, status: 200).facts
          ::Books::GoodreadsPage.new({
            goodreads_book_id: 147719920, title: facts.title, genres: facts.genres,
            series: facts.series.map { |s| {"goodreads_series_id" => s.goodreads_series_id, "title" => s.title, "position" => s.position} },
            authors: facts.contributors.map { |c| {"name" => c.name, "role" => c.role, "primary" => c.primary} }
          }.merge(overrides))
        end

        test "the stray Catch-22 edition page passes" do
          verdict = PageCheck.call(book: @book, page: stray_page)

          assert_equal [true, nil], [verdict.ok, verdict.reason]
        end

        test "another author is an author_mismatch" do
          page = stray_page(authors: [{"name" => "Someone Else", "role" => "Author", "primary" => true}])

          assert_equal "author_mismatch", PageCheck.call(book: @book, page: page).reason
        end

        test "another title is a title_mismatch" do
          assert_equal "title_mismatch", PageCheck.call(book: @book, page: stray_page(title: "Closing Time")).reason
        end

        test "an adaptation title is derivative" do
          assert_equal "derivative", PageCheck.call(book: @book, page: stray_page(title: "Catch-22: The Graphic Novel")).reason
        end

        test "a Study Guides genre is a study_aid" do
          assert_equal "study_aid", PageCheck.call(book: @book, page: stray_page(genres: ["Fiction", "Study Guides"])).reason
        end

        test "a ranged series position is a set" do
          page = stray_page(series: [{"goodreads_series_id" => 1, "title" => "Catch-22", "position" => "1-3"}])

          assert_equal "set", PageCheck.call(book: @book, page: page).reason
        end

        test "a title carrying set words is a set" do
          assert_equal "set", PageCheck.call(book: @book, page: stray_page(title: "Catch-22 Omnibus")).reason
        end
      end
    end
  end
end
