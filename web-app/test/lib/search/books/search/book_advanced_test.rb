# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookAdvancedTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        def criteria(hash)
          ::Books::SavedSearchCriteria.new(hash)
        end

        # Indexes a document directly so a test controls every field, rather
        # than depending on a fixture book's associations.
        def index_book(id, attrs = {})
          ::Search::Base::Search.client.index(
            index: ::Search::Books::BookIndex.index_name,
            id: id,
            body: {
              title: "Book #{id}",
              category_ids: [],
              original_language_id: nil,
              country_ids: [],
              book_length: nil,
              first_published_year: nil,
              ranked: false,
              ranked_position: nil
            }.merge(attrs),
            refresh: true
          )
        end

        def ids_for(hash, **options)
          ::Search::Books::Search::BookAdvanced.call(criteria(hash), **options)[:ids]
        end

        test "returns every book when the criteria carry no filters" do
          index_book(1)
          index_book(2)

          result = ::Search::Books::Search::BookAdvanced.call(criteria({"genre_match_mode" => "any"}))

          assert_equal [1, 2], result[:ids].sort
          assert_equal 2, result[:total]
        end

        test "filters included categories in any mode" do
          index_book(1, category_ids: [10])
          index_book(2, category_ids: [20])

          assert_equal [1], ids_for({"included_category_ids" => ["10"]})
        end

        test "requires every category in all mode" do
          index_book(1, category_ids: [10, 20])
          index_book(2, category_ids: [10])

          assert_equal [1], ids_for({"included_category_ids" => ["10", "20"], "genre_match_mode" => "all"})
        end

        test "excludes categories" do
          index_book(1, category_ids: [10])
          index_book(2, category_ids: [20])

          assert_equal [2], ids_for({"excluded_category_ids" => ["10"]})
        end

        test "filters and excludes languages" do
          index_book(1, original_language_id: 5)
          index_book(2, original_language_id: 6)

          assert_equal [1], ids_for({"included_language_ids" => ["5"]})
          assert_equal [2], ids_for({"excluded_language_ids" => ["5"]})
        end

        test "filters and excludes countries" do
          index_book(1, country_ids: [7])
          index_book(2, country_ids: [8])

          assert_equal [1], ids_for({"included_country_ids" => ["7"]})
          assert_equal [2], ids_for({"excluded_country_ids" => ["7"]})
        end

        test "filters book_length" do
          index_book(1, book_length: 1)
          index_book(2, book_length: 4)

          assert_equal [1], ids_for({"book_length" => [1]})
        end

        test "filters a publication year range on either bound" do
          index_book(1, first_published_year: 1975)
          index_book(2, first_published_year: 1985)
          index_book(3, first_published_year: 1995)

          assert_equal [2, 3], ids_for({"first_year_published_gt" => "1980"}).sort
          assert_equal [1, 2], ids_for({"first_year_published_lt" => "1990"}).sort
          assert_equal [2], ids_for({"first_year_published_gt" => "1980", "first_year_published_lt" => "1990"})
        end

        test "resolves book_type to a category id" do
          category = ::Books::Category.create!(name: "Advanced Fiction Genre", category_type: :genre)
          LegacyIdMap.record(model: "Books::Category", legacy_id: 40348, new_id: category.id)
          ::Books::BookType.reset_category_ids!
          index_book(1, category_ids: [category.id])
          index_book(2, category_ids: [999])

          assert_equal [1], ids_for({"book_type" => 0})
        ensure
          ::Books::BookType.reset_category_ids!
        end

        test "ranked true keeps only books carrying a ranked_position" do
          index_book(1, ranked_position: 5)
          index_book(2, ranked_position: nil)

          assert_equal [1], ids_for({"ranked" => "true"})
        end

        test "ranked false keeps only books without a ranked_position" do
          index_book(1, ranked_position: 5)
          index_book(2, ranked_position: nil)

          assert_equal [2], ids_for({"ranked" => "false"})
        end

        test "an absent ranked criterion keeps both" do
          index_book(1, ranked_position: 5)
          index_book(2, ranked_position: nil)

          assert_equal [1, 2], ids_for({}).sort
        end

        test "max_ranked_position bounds the rank and excludes unranked books" do
          index_book(1, ranked_position: 50)
          index_book(2, ranked_position: 150)
          index_book(3, ranked_position: nil)

          assert_equal [1], ids_for({"max_ranked_position" => 100})
        end

        test "max_ranked_position with ranked false returns nothing" do
          index_book(1, ranked_position: 50)

          assert_equal [], ids_for({"max_ranked_position" => 100, "ranked" => "false"})
        end

        # Spec §6: unknown ids match nothing rather than 404. A saved search is
        # private user data, not an indexable URL space -- the opposite of the
        # public-filters spec's choice, and deliberately so.
        test "an unknown category id matches nothing rather than raising" do
          index_book(1, category_ids: [10])

          result = ::Search::Books::Search::BookAdvanced.call(criteria({"included_category_ids" => ["999999"]}))

          assert_equal [], result[:ids]
          assert_equal 0, result[:total]
        end

        test "excluded_book_ids removes those books" do
          index_book(1)
          index_book(2)

          assert_equal [2], ids_for({}, excluded_book_ids: [1])
        end

        test "an empty excluded_book_ids excludes nothing" do
          index_book(1)

          assert_equal [1], ids_for({}, excluded_book_ids: [])
        end

        test "sorts ranked books first by position, then unranked by year" do
          index_book(1, ranked_position: 200, first_published_year: 1900)
          index_book(2, ranked_position: 10, first_published_year: 2000)
          index_book(3, ranked_position: nil, first_published_year: 1950)

          assert_equal [2, 1, 3], ids_for({})
        end

        test "pages through results" do
          index_book(1, ranked_position: 1)
          index_book(2, ranked_position: 2)
          index_book(3, ranked_position: 3)

          assert_equal [1, 2], ids_for({}, page: 1, per_page: 2)
          assert_equal [3], ids_for({}, page: 2, per_page: 2)
        end

        test "total counts every match, not just the page" do
          index_book(1, ranked_position: 1)
          index_book(2, ranked_position: 2)
          index_book(3, ranked_position: 3)

          result = ::Search::Books::Search::BookAdvanced.call(criteria({}), page: 1, per_page: 2)

          assert_equal 2, result[:ids].size
          assert_equal 3, result[:total]
        end

        # The `all` mode is the one clause whose SHAPE matters rather than its
        # effect: it must build one term filter per id, not a single terms.
        test "all mode builds one term filter per category id" do
          definition = ::Search::Books::Search::BookAdvanced.build_query_definition(
            criteria({"included_category_ids" => ["10", "20"], "genre_match_mode" => "all"})
          )
          filters = definition[:query][:bool][:filter]

          assert_includes filters, {term: {category_ids: 10}}
          assert_includes filters, {term: {category_ids: 20}}
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
