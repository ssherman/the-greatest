# frozen_string_literal: true

require "test_helper"

module CsvExports
  module Books
    class RankedBookRowTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_global)
        @book = books_books(:war_and_peace)
        @ranked = RankedItem.create!(item: @book, ranking_configuration: @config, rank: 1, score: 99.5)
      end

      test "headers" do
        assert_equal ["Rank", "Score", "ID", "Title", "Authors", "Year", "Original Language", "Countries",
          "Genres", "Subjects", "Locations", "Page Range", "Word Count", "URL"], RankedBookRow::HEADERS
      end

      test "a row from a ranked item" do
        ctx = RankedBookRow.context([@book.id])

        assert_equal [
          1, "99.50", @book.id, "War and Peace", "Leo Tolstoy", 1869, "Russian", "French",
          "Classics, Novels", nil, nil, nil, nil,
          "#{Api::Host.base_url(:books)}/book/war-and-peace"
        ], RankedBookRow.row(@ranked, ctx)
      end

      test "a row for a hydrated book carries the rank and score it is given" do
        ctx = RankedBookRow.context([@book.id])

        row = RankedBookRow.row_for_book(@book, rank: 7, score: 12, ctx: ctx)

        assert_equal 7, row[0]
        assert_equal "12.00", row[1]
      end

      test "a soft-deleted category is left out" do
        # update_columns: Category's save callbacks enqueue search reindexing,
        # which is not what this test is about.
        categories(:books_classics_genre).update_columns(deleted: true)

        ctx = RankedBookRow.context([@book.id])

        assert_equal "Novels", RankedBookRow.row(@ranked, ctx)[8]
      end

      test "unranked scores and missing authors are blank cells" do
        # insert_all, as the controller tests seed books: no model callbacks.
        id = ::Books::Book.insert_all([{title: "Nobody Wrote This", slug: "nobody-wrote-this",
                                        created_at: Time.current, updated_at: Time.current}], returning: :id).rows.flatten.first
        book = ::Books::Book.find(id)
        ranked = RankedItem.create!(item: book, ranking_configuration: @config, rank: 2, score: nil)
        ctx = RankedBookRow.context([book.id])

        row = RankedBookRow.row(ranked, ctx)

        assert_nil row[1]
        assert_nil row[4]
      end

      test "preloads only the belongs_to columns the row reads" do
        assert_equal [:original_language], RankedBookRow.preloads
      end

      test "the Unknown placeholder country is left out, as on the book page" do
        ::Books::BookCountry.create!(book: @book, country: books_countries(:unknown))

        ctx = RankedBookRow.context([@book.id])

        assert_equal "French", RankedBookRow.row(@ranked, ctx)[7]
      end

      test "genres, subjects and locations land in their own columns" do
        book = books_books(:crime_and_punishment)
        ranked = RankedItem.create!(item: book, ranking_configuration: @config, rank: 2, score: 90)

        row = RankedBookRow.row(ranked, RankedBookRow.context([book.id]))

        assert_equal ["Novels", "Politics", "France"], row[8..10]
      end

      test "several authors are joined in insertion order and page range and word count are carried" do
        other = ::Books::Author.insert_all([{name: "Second Author", slug: "second-author",
                                             created_at: Time.current, updated_at: Time.current}], returning: :id).rows.flatten.first
        ::Books::BookAuthor.insert_all([{book_id: @book.id, author_id: other, position: nil,
                                         created_at: Time.current, updated_at: Time.current}])
        @book.update_columns(page_range: "300-350", word_count: 587_287)

        row = RankedBookRow.row(@ranked.reload, RankedBookRow.context([@book.id]))

        assert_equal "Leo Tolstoy, Second Author", row[4]
        assert_equal ["300-350", 587_287], row[11..12]
      end
    end
  end
end
