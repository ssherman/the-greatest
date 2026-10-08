# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookRecommendationsTest < ActiveSupport::TestCase
        G1 = "9101"
        G2 = "9102"
        S1 = "9201"
        FICTION = "9301"
        NONFICTION = "9302"
        TYPE_IDS = {"Fiction" => 9301, "Nonfiction" => 9302}.freeze

        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        def cleanup_test_index
          ::Search::Books::BookIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end

        def index_book(id, attrs = {})
          genres = attrs.fetch(:genre_category_ids, [])
          subjects = attrs.fetch(:subject_category_ids, [])
          ::Search::Base::Search.client.index(
            index: ::Search::Books::BookIndex.index_name, id: id, refresh: true,
            body: {
              title: "Book #{id}",
              category_ids: genres + subjects,
              genre_category_ids: genres,
              subject_category_ids: subjects,
              location_category_ids: [],
              similarity_category_count: attrs.fetch(:similarity_category_count, 10),
              author_ids: [], original_language_id: nil, country_ids: [],
              book_length: attrs[:book_length], first_published_year: attrs[:first_published_year],
              ranked: true,
              ranked_position: attrs.fetch(:ranked_position, id),
              provisional: attrs.fetch(:provisional, false)
            }
          )
        end

        def profile(genres: [[9101, 2.0], [9102, 1.0]], subjects: [], demoted: [], fiction_share: nil)
          Recommendations::Profile.new(genres: genres, subjects: subjects, locations: [], demoted: demoted,
            fiction_share: fiction_share, genre_distribution: {}, counts: {})
        end

        def criteria(raw = {})
          ::Books::RecommendationCriteria.new(raw)
        end

        def ids(profile: self.profile, criteria: self.criteria, excluded_ids: [], **options)
          BookRecommendations.call(profile: profile, criteria: criteria, excluded_ids: excluded_ids,
            type_category_ids: TYPE_IDS, options: {min_score: 0}.merge(options)).map { |h| h[:id] }
        end

        test "shared categories add up: two matches outrank one" do
          index_book(1, genre_category_ids: [G1])
          index_book(2, genre_category_ids: [G1, G2])
          assert_equal [2, 1], ids
        end

        test "boosts scale with profile weight and type multiplier" do
          index_book(1, genre_category_ids: [G1])            # 2.0 * 1.0 = 2.0
          index_book(2, subject_category_ids: [S1])          # 2.4 * 0.8 = 1.92 (2.4 if the multiplier were ignored)
          assert_equal [1, 2], ids(profile: profile(genres: [[9101, 2.0]], subjects: [[9201, 2.4]]))
        end

        test "excluded ids and provisional books never return" do
          index_book(1, genre_category_ids: [G1])
          index_book(2, genre_category_ids: [G1])
          index_book(3, genre_category_ids: [G1], provisional: true)
          assert_equal [1], ids(excluded_ids: [2])
        end

        test "criteria apply as hard filters" do
          index_book(1, genre_category_ids: [G1], ranked_position: 10, book_length: 1, first_published_year: 1950)
          index_book(2, genre_category_ids: [G1], ranked_position: 900, book_length: 1, first_published_year: 1950)
          index_book(3, genre_category_ids: [G1], ranked_position: 20, book_length: 4, first_published_year: 1950)
          index_book(4, genre_category_ids: [G1], ranked_position: 30, book_length: 1, first_published_year: 1800)
          index_book(5, genre_category_ids: [G1, S1], ranked_position: 40, book_length: 1, first_published_year: 1950)
          assert_equal [1], ids(criteria: criteria("max_ranked_position" => 100, "book_length" => [1],
            "first_year_published_gt" => 1900, "excluded_category_ids" => [9201]))
        end

        test "an unparseable criterion matches nothing" do
          index_book(1, genre_category_ids: [G1])
          assert_equal [], ids(criteria: criteria("max_ranked_position" => "abc"))
        end

        test "a demoted category scales the score down instead of excluding" do
          index_book(1, genre_category_ids: [G1])
          index_book(2, genre_category_ids: [G1], subject_category_ids: [S1])
          result = BookRecommendations.call(profile: profile(demoted: [9201]), criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS, options: {min_score: 0})
          assert_equal [1, 2], result.map { |h| h[:id] }
          assert_in_delta result[0][:score] * 0.3, result[1][:score], 0.01
        end

        test "a high fiction share demotes nonfiction-only books but not books tagged both" do
          index_book(1, genre_category_ids: [G1, NONFICTION])
          index_book(2, genre_category_ids: [G1, FICTION, NONFICTION])
          index_book(3, genre_category_ids: [G1, FICTION])
          result = ids(profile: profile(fiction_share: 0.95))
          assert_equal 1, result.last, "the nonfiction-only book sinks"
          assert_includes result.first(2), 2
        end

        test "normalization divides by sqrt(count) above the floor" do
          index_book(1, genre_category_ids: [G1], similarity_category_count: 10)
          index_book(2, genre_category_ids: [G1], similarity_category_count: 40)
          index_book(3, genre_category_ids: [G1], similarity_category_count: 3)
          result = BookRecommendations.call(profile: profile, criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS, options: {min_score: 0})
          scores = result.to_h { |h| [h[:id], h[:score]] }
          assert_in_delta scores[1], scores[3], 0.001, "the floor clamps the thin book to the same denominator"
          assert_in_delta scores[1] / 2, scores[2], 0.001
        end

        test "the quality prior multiplies the score by a rank decay with a floor" do
          index_book(1, genre_category_ids: [G1], ranked_position: 1)
          index_book(2, genre_category_ids: [G1], ranked_position: 1000)
          base = BookRecommendations.call(profile: profile, criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS, options: {min_score: 0}).to_h { |h| [h[:id], h[:score]] }
          assert_in_delta base[1], base[2], 0.0001, "scale 0 leaves scores untouched by rank"

          result = BookRecommendations.call(profile: profile, criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS, options: {min_score: 0, quality_scale: 1000, quality_floor: 0.2})
          assert_equal [1, 2], result.map { |h| h[:id] }
          scores = result.to_h { |h| [h[:id], h[:score]] }
          assert_in_delta base[1] * (0.2 + 0.8 * 1000.0 / 1001), scores[1], 0.001
          assert_in_delta base[2] * (0.2 + 0.8 * 0.5), scores[2], 0.001
        end

        test "returns the rank position from doc values" do
          index_book(1, genre_category_ids: [G1], ranked_position: 37)
          hit = BookRecommendations.call(profile: profile, criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS, options: {min_score: 0}).first
          assert_equal 37, hit[:rank_position]
        end

        test "an empty profile sends no query" do
          BookRecommendations.expects(:search).never
          assert_equal [], BookRecommendations.call(profile: profile(genres: []), criteria: criteria, excluded_ids: [],
            type_category_ids: TYPE_IDS)
        end

        test "min_score drops weak matches" do
          index_book(1, genre_category_ids: [G1])
          assert_equal [], ids(min_score: 100)
        end

        test "ranked_only returns the filtered pool in rank order" do
          index_book(1, ranked_position: 30)
          index_book(2, ranked_position: 10)
          index_book(3, ranked_position: 20, provisional: true)
          index_book(4, ranked_position: 5)
          result = BookRecommendations.ranked_only(criteria: criteria, excluded_ids: [4], options: {candidate_size: 10})
          assert_equal [2, 1], result.map { |h| h[:id] }
          assert_equal 10, result.first[:rank_position]
        end
      end
    end
  end
end
