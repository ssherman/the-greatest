require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class EditionQueryTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        test "builds the finder query from the edition's parsed fields" do
          edition = goodreads_edition(title: "Mistborn", primary_author: "Brandon Sanderson", series_name: "Mistborn",
            series_number: "1", additional_authors: ["Some Narrator"], isbn13: "9780765311788", isbn10: "076531178X",
            original_publication_year: 2006, year_published: 2007)

          query = EditionQuery.call(edition)

          assert_equal "Mistborn", query.title
          assert_equal ["Brandon Sanderson"], query.author_names
          assert_equal 2006, query.year
          assert_equal ["9780765311788"], query.isbn13
          assert_equal ["076531178X"], query.isbn10
          assert_equal [edition.goodreads_book_id.to_s], query.goodreads_id
          assert_equal ["Mistborn", "1"], [query.series_name, query.series_number]
          assert_equal ["Some Narrator"], query.context_author_names
        end

        test "falls back to the edition's own year" do
          edition = goodreads_edition(year_published: 1999)

          assert_equal 1999, EditionQuery.call(edition).year
        end
      end
    end
  end
end
