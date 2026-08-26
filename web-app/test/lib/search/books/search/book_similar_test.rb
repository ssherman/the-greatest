# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookSimilarTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
          @book = books_books(:crime_and_punishment)
          @novels = categories(:books_novels_genre).id.to_s      # item_count 300
          @classics = categories(:books_classics_genre).id.to_s   # item_count 100
          @politics = categories(:books_politics_subject).id.to_s # item_count 200
          @france = categories(:books_france_location).id.to_s    # item_count 50
        end

        def teardown
          cleanup_test_index
        end

        # Indexes a document directly so a test controls every field, rather than
        # depending on a fixture book's associations.
        def index_book(id, attrs = {})
          ::Search::Base::Search.client.index(
            index: ::Search::Books::BookIndex.index_name,
            id: id,
            body: {
              title: "Book #{id}",
              category_ids: [],
              genre_category_ids: [],
              subject_category_ids: [],
              location_category_ids: [],
              similarity_category_count: 0,
              author_ids: [],
              original_language_id: nil,
              country_ids: [],
              book_length: nil,
              first_published_year: nil,
              ranked: true,
              ranked_position: nil
            }.merge(attrs),
            refresh: true
          )
        end

        def ids_for(book: @book, **options)
          ::Search::Books::Search::BookSimilar.call(book, options).map { |hit| hit[:id] }
        end

        test "returns nothing when the book has no scoring categories" do
          # of_mice_and_men carries no category items in the fixtures.
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_empty ::Search::Books::Search::BookSimilar.call(books_books(:of_mice_and_men))
        end

        test "excludes the book itself" do
          index_book(@book.id, genre_category_ids: [@novels], similarity_category_count: 1)
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_equal ["9001"], ids_for
        end

        test "excludes unranked books" do
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1, ranked: false)

          assert_empty ids_for
        end

        test "normalizing by category count ranks a tight match above a bloated one" do
          # 9001 shares one genre out of two tags -- most of what it is.
          # 9002 shares two categories but carries forty tags -- a grab bag.
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 2)
          index_book(9002,
            genre_category_ids: [@novels],
            subject_category_ids: [@politics],
            similarity_category_count: 40)

          assert_equal ["9002", "9001"], ids_for(normalize_by_category_count: false)
          assert_equal ["9001", "9002"], ids_for(normalize_by_category_count: true)
        end

        test "requiring a genre match drops a book that shares only a location" do
          index_book(9001, location_category_ids: [@france], similarity_category_count: 1)

          assert_equal ["9001"], ids_for(require_genre_match: false)
          assert_empty ids_for(require_genre_match: true)
        end

        test "dropping common categories ignores a match on an over-common genre" do
          # war_and_peace carries two genres: novels (item_count 300) and
          # classics (100). A ceiling of 150 culls novels but classics
          # survives, so the guard does not fire and genre stays required --
          # just on classics now, which this doc doesn't share.
          war_and_peace = books_books(:war_and_peace)
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_equal ["9001"], ids_for(book: war_and_peace, drop_common_categories: false)
          assert_empty ids_for(book: war_and_peace, drop_common_categories: true, max_category_item_count: 150)
        end

        test "keeps the rarest genre when the ceiling would remove every one of them" do
          # A ceiling of 1 is below BOTH of war_and_peace's genres (novels 300,
          # classics 100), so without the guard neither survives and
          # require_genre_match turns itself off entirely, matching anything.
          # The guard restores exactly the rarer genre (classics): 9001
          # (shares classics) is found, while 9002 (shares only novels, the
          # genre NOT restored) stays excluded -- proving the guard kept one
          # genre rather than abandoning the ceiling.
          war_and_peace = books_books(:war_and_peace)
          index_book(9001, genre_category_ids: [@classics], similarity_category_count: 1)
          index_book(9002, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_equal ["9001"], ids_for(book: war_and_peace, drop_common_categories: true, max_category_item_count: 1)
        end

        test "excludes books sharing a series with the source book" do
          sibling = books_books(:got)
          series = ::Books::Series.create!(title: "Similarity Test Series")
          ::Books::SeriesBook.create!(series: series, book: @book)
          ::Books::SeriesBook.create!(series: series, book: sibling)
          index_book(sibling.id, genre_category_ids: [@novels], similarity_category_count: 1)

          assert_equal [sibling.id.to_s], ids_for(exclude_same_series: false)
          assert_empty ids_for(exclude_same_series: true)
        end

        test "size is limit times over_fetch" do
          6.times { |i| index_book(9000 + i, genre_category_ids: [@novels], similarity_category_count: 1) }

          assert_equal 6, ids_for(limit: 2, over_fetch: 3).size
        end

        private

        def cleanup_test_index
          ::Search::Books::BookIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
