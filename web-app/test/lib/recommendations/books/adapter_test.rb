# frozen_string_literal: true

require "test_helper"

module Recommendations
  module Books
    class AdapterTest < ActiveSupport::TestCase
      # Fixtures: regular_user favorites = war_and_peace (pos 1), got (pos 2);
      # read = clash; reviews = war_and_peace ★5, crime_and_punishment ★3.
      def setup
        @user = users(:regular_user)
        @adapter = Adapter.new(config: Config.resolve)
        @want = ::Books::UserList.create!(user: @user, list_type: :want_to_read, name: "Want")
        @want.user_list_items.create!(listable: books_books(:of_mice_and_men))
        Review.create!(user: @user, reviewable: books_books(:cannery_row), rating: 1)
      end

      def interaction(book)
        @adapter.interactions(@user).find { |i| i.item_id == books_books(book).id }
      end

      test "favorites take the favorite weight plus the rating weight" do
        assert_in_delta 2.0 + 0.75 * 2, interaction(:war_and_peace).weight, 0.001
        assert_equal :favorite, interaction(:war_and_peace).kind
        assert_equal 5, interaction(:war_and_peace).rating
      end

      test "an unordered favorites list earns no top-favorite bonus" do
        assert_in_delta 2.0, interaction(:got).weight, 0.001
      end

      test "a manually ordered favorites list adds the bonus to its top entries" do
        user_lists(:regular_user_books_favorites).update!(manually_ordered: true)
        assert_in_delta 2.5, interaction(:got).weight, 0.001
      end

      test "read, want-to-read, and ratings map to their weights" do
        assert_in_delta 0.4, interaction(:clash).weight, 0.001
        assert_equal :read, interaction(:clash).kind
        assert_in_delta 0.2, interaction(:of_mice_and_men).weight, 0.001
        assert_equal :want_to_read, interaction(:of_mice_and_men).kind
        assert_in_delta(-1.1, interaction(:cannery_row).weight, 0.001, "unlisted review: read weight 0.4 plus rating weight -1.5")
        assert_equal :review, interaction(:cannery_row).kind
        assert_in_delta 0.4, interaction(:crime_and_punishment).weight, 0.001
        assert_equal :review, interaction(:crime_and_punishment).kind
      end

      test "a text-only review counts as read" do
        Review.create!(user: @user, reviewable: books_books(:combo_steinbeck), body: "Fine.")
        assert_in_delta 0.4, interaction(:combo_steinbeck).weight, 0.001
        assert_nil interaction(:combo_steinbeck).rating
      end

      test "custom lists contribute no interaction" do
        custom = ::Books::UserList.create!(user: @user, list_type: :custom, name: "Shelf")
        custom.user_list_items.create!(listable: books_books(:combo_steinbeck))
        assert_nil interaction(:combo_steinbeck)
      end

      test "shelved ids include every list (custom and want-to-read) and every review" do
        custom = ::Books::UserList.create!(user: @user, list_type: :custom, name: "Shelf")
        custom.user_list_items.create!(listable: books_books(:combo_steinbeck))
        expected = %i[war_and_peace got clash of_mice_and_men cannery_row crime_and_punishment combo_steinbeck]
          .map { |k| books_books(k).id }.sort
        assert_equal expected, @adapter.shelved_item_ids(@user).sort
      end

      test "categories_for returns scoring categories with type and item_count" do
        facts = @adapter.categories_for([books_books(:crime_and_punishment).id])[books_books(:crime_and_punishment).id]
        by_name = facts.index_by { |f| ::Books::Category.find(f.id).name }
        assert_equal "genre", by_name["Novels"].category_type
        assert_equal 300, by_name["Novels"].item_count
        assert_equal "subject", by_name["Politics"].category_type
        assert_equal "location", by_name["France"].category_type
      end

      test "categories_for skips soft-deleted categories" do
        CategoryItem.create!(category: categories(:books_deleted_genre), item: books_books(:got))
        ids = @adapter.categories_for([books_books(:got).id]).fetch(books_books(:got).id).map(&:id)
        assert_not_includes ids, categories(:books_deleted_genre).id
      end

      test "type_category_ids resolves Fiction and Nonfiction by name" do
        ids = @adapter.type_category_ids
        assert_equal categories(:books_fiction_genre).id, ids["Fiction"]
        assert_equal categories(:books_nonfiction_genre).id, ids["Nonfiction"]
      end

      test "item_facts carry authors, genres, series predecessor and rank" do
        facts = @adapter.item_facts([books_books(:got).id, books_books(:clash).id])
        got = facts[books_books(:got).id]
        clash = facts[books_books(:clash).id]
        assert_equal [books_authors(:king).id], got.author_ids
        assert_includes got.genre_ids, categories(:books_novels_genre).id
        assert_nil got.series_predecessor_id, "position 1 has no predecessor"
        assert_equal books_books(:got).id, clash.series_predecessor_id, "the unnumbered novella at 1.5 is skipped"
        assert_nil got.rank_position
      end

      test "item_facts reports the rank in the default primary ranking" do
        RankedItem.create!(item: books_books(:got), ranking_configuration: ranking_configurations(:books_global), rank: 7)
        assert_equal 7, @adapter.item_facts([books_books(:got).id])[books_books(:got).id].rank_position
      end

      test "load_items indexes books by id with authors preloaded" do
        ids = [books_books(:got).id, books_books(:clash).id]
        books = @adapter.load_items(ids)
        assert_equal ids.sort, books.keys.sort
        assert books.values.all?(::Books::Book)
        book = books[books_books(:got).id]
        assert book.association(:book_authors).loaded?
        assert_not_empty book.book_authors
        assert book.book_authors.first.association(:author).loaded?
      end

      test "criteria_for returns the stored criteria or an empty one" do
        assert_equal 500, @adapter.criteria_for(@user).max_ranked_position
        assert_nil @adapter.criteria_for(users(:editor_user)).max_ranked_position
      end

      test "catalog_size counts non-provisional books" do
        assert_equal ::Books::Book.catalog.count, @adapter.catalog_size
      end

      test "lift_population ranked sizes and counts categories over the ranked pool" do
        primary = ::Books::RankingConfiguration.default_primary
        got = books_books(:got)
        ::RankedItem.create!(item: got, ranking_configuration: primary, rank: 1)
        ::RankedItem.create!(item: books_books(:clash), ranking_configuration: primary, rank: 2)
        ::RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: primary, rank: nil)
        ::RankedItem.create!(item: books_books(:cannery_row), ranking_configuration: ranking_configurations(:books_user), rank: 1)
        epic = ::Books::Category.create!(name: "Epic fantasy", category_type: :genre)
        [got, books_books(:war_and_peace), books_books(:cannery_row)].each do |book|
          ::CategoryItem.create!(category: epic, item: book)
        end

        ranked = Adapter.new(config: Config.resolve(lift_population: "ranked"))
        assert_equal 2, ranked.catalog_size
        fact = ranked.categories_for([got.id]).fetch(got.id).find { |f| f.id == epic.id }
        assert_equal 1, fact.item_count, "only the ranked book carrying the category counts"

        catalog_fact = @adapter.categories_for([got.id]).fetch(got.id).find { |f| f.id == epic.id }
        assert_equal 3, catalog_fact.item_count
      end

      test "search_candidates maps hits to candidates with taste evidence" do
        ::Search::Books::Search::BookRecommendations.stubs(:call).returns([{id: 5, score: 2.5, rank_position: 12}])
        profile = Recommendations::Profile.new(genres: [[1, 1.0]], subjects: [], locations: [], demoted: [],
          fiction_share: nil, genre_distribution: {}, counts: {})
        candidates = @adapter.search_candidates(profile: profile, criteria: @adapter.criteria_for(@user), excluded_ids: [], size: 10)
        assert_equal [Recommendations::Candidate.new(item_id: 5, score: 2.5, rank_position: 12, evidence: {taste: true})], candidates
      end

      test "rank_ordered_candidates maps hits to candidates with empty evidence" do
        ::Search::Books::Search::BookRecommendations.stubs(:ranked_only).returns([{id: 5, score: 0.0, rank_position: 1}])
        candidates = @adapter.rank_ordered_candidates(criteria: @adapter.criteria_for(@user), excluded_ids: [], size: 10)
        assert_equal({}, candidates.first.evidence)
        assert_equal 1, candidates.first.rank_position
      end

      test "domain names the registry key" do
        assert_equal :books, @adapter.domain
      end

      test "filter_candidate_ids asks the query only when there is something to ask" do
        assert_equal({}, @adapter.filter_candidate_ids([], criteria: ::Books::RecommendationCriteria.new({}), excluded_ids: []))
        ::Search::Books::Search::BookRecommendations.expects(:ranked_only)
          .with { |**kw| kw[:ids] == [5, 6] && kw[:options][:candidate_size] == 2 && kw[:excluded_ids] == [7] }
          .returns([{id: 6, score: 0.0, rank_position: 12}])
        kept = @adapter.filter_candidate_ids([5, 6], criteria: ::Books::RecommendationCriteria.new({}), excluded_ids: [7])
        assert_equal({6 => 12}, kept)
      end
    end
  end
end
