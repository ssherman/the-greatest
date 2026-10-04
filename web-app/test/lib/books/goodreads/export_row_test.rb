# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class ExportRowTest < ActiveSupport::TestCase
      def row(fields)
        ExportRow.new(row_number: 1, fields: {"Book Id" => "4671", "Title" => "The Great Gatsby", "Author" => "F. Scott Fitzgerald"}.merge(fields))
      end

      test "the Goodreads id is read from a slug form" do
        assert_equal 32076670, row("Book Id" => "32076670-ball-lightning").goodreads_book_id
      end

      test "a trailing series suffix is split off and kept" do
        parsed = row("Title" => "The Final Empire (Mistborn, #1)")

        assert_equal ["The Final Empire", "Mistborn", "1"], [parsed.title, parsed.series_name, parsed.series_number]
      end

      test "a series suffix without a comma or with a range still splits" do
        assert_equal ["Dune", "Dune", "1"], row("Title" => "Dune (Dune #1)").then { |r| [r.title, r.series_name, r.series_number] }
        assert_equal "1-3", row("Title" => "The Trilogy (Saga, #1-3)").series_number
      end

      test "nothing after a colon is dropped, and a parenthetical without a number stays in the title" do
        assert_equal "Mistborn: The Final Empire", row("Title" => "Mistborn: The Final Empire").title
        assert_equal "Poems (Selected)", row("Title" => "Poems (Selected)").title
        assert_nil row("Title" => "Poems (Selected)").series_name
      end

      test "an earlier parenthetical survives when the series suffix is split" do
        assert_equal "Title (A Note)", row("Title" => "Title (A Note) (Series, #2)").title
      end

      test "only the primary author is an author; additional authors are a list beside it" do
        parsed = row("Author" => "Cixin  Liu", "Additional Authors" => "Ken Liu, Joel Martinsen")

        assert_equal "Cixin Liu", parsed.primary_author
        assert_equal ["Ken Liu", "Joel Martinsen"], parsed.additional_authors
      end

      test "ISBNs are unwrapped and each derives the other" do
        parsed = row("ISBN" => '="0441013597"', "ISBN13" => '=""')

        assert_equal ["9780441013593", "0441013597"], [parsed.isbn13, parsed.isbn10]
      end

      test "an invalid ISBN is dropped and noted" do
        parsed = row("ISBN13" => '="9780441013594"')

        assert_nil parsed.isbn13
        assert_includes parsed.notes, 'invalid ISBN13 dropped: ="9780441013594"'
      end

      test "both years are read, including a year before the common era" do
        parsed = row("Original Publication Year" => "-750", "Year Published" => "1999")

        assert_equal [-750, 1999], [parsed.original_publication_year, parsed.year_published]
      end

      test "user fields are read" do
        parsed = row(
          "Exclusive Shelf" => "Read", "Bookshelves" => "favorites, sci-fi, favorites",
          "Bookshelves with positions" => "favorites (#4), sci-fi (#12)", "My Rating" => "4",
          "My Review" => "Loved it.<br/>Twice.", "Date Read" => "2024/05/03", "Date Added" => "2023/1/9",
          "Read Count" => "2"
        )

        assert_equal "read", parsed.exclusive_shelf
        assert_equal ["favorites", "sci-fi"], parsed.shelves
        assert_equal({"favorites" => 4, "sci-fi" => 12}, parsed.shelf_positions)
        assert_equal [4, "Loved it.<br/>Twice.", 2], [parsed.rating, parsed.review_body, parsed.read_count]
        assert_equal [Date.new(2024, 5, 3), Date.new(2023, 1, 9)], [parsed.date_read, parsed.date_added]
        assert_equal [], parsed.notes
      end

      test "a rating of zero is kept; one out of range is dropped and noted" do
        assert_equal 0, row("My Rating" => "0").rating
        parsed = row("My Rating" => "7")

        assert_nil parsed.rating
        assert_includes parsed.notes, "unreadable My Rating dropped: 7"
      end

      test "a bad date is dropped and noted" do
        parsed = row("Date Read" => "2024/13/45")

        assert_nil parsed.date_read
        assert_includes parsed.notes, "unreadable Date Read dropped: 2024/13/45"
      end

      test "Private Notes never reaches raw" do
        parsed = row("Private Notes" => "my secret", "My Review" => "public")

        assert_not parsed.raw.key?("Private Notes")
        assert_equal "public", parsed.raw["My Review"]
      end

      test "a row with no id, title or author is invalid and says why" do
        parsed = ExportRow.new(row_number: 3, fields: {"Book Id" => "", "Title" => " ", "Author" => nil})

        assert_not parsed.valid?
        assert_equal ["no Goodreads book id", "no title", "no author"], parsed.errors
      end

      test "honest variants of one title and author share a signature; another title does not" do
        plain = row("Title" => "Dune", "Author" => "Frank Herbert").signature

        assert_equal plain, row("Title" => "Dune (Dune, #1)", "Author" => "Frank  Herbert").signature
        assert_equal plain, row("Title" => "DUNE", "Author" => "frank herbert").signature
        assert_not_equal plain, row("Title" => "Dune Messiah", "Author" => "Frank Herbert").signature
      end
    end
  end
end
