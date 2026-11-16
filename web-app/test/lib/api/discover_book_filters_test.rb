require "test_helper"

module Api
  class DiscoverBookFiltersTest < ActiveSupport::TestCase
    def filter(hash = {})
      Api::DiscoverBookFilters.call(ActionController::Parameters.new(hash))
    end

    def assert_invalid(hash, *names)
      error = assert_raises(Api::Page::InvalidParameter) { filter(hash) }
      names.each { |name| assert_includes error.message, name }
    end

    test "every parameter sent produces the exact criteria and applied" do
      result = filter(
        category_id: "novels,fiction", category_match: "any", exclude_category_id: "politics",
        country_id: "japanese,french", exclude_country_id: "unknown",
        language: "french", exclude_language: "english",
        length: "long,short", published_start: "1800", published_end: "1899",
        ranked: "ranked", rank_min: "5", rank_max: "50", hide_read: "true"
      )

      assert_equal({
        "genre_match_mode" => "any",
        "included_category_ids" => [categories(:books_fiction_genre).id, categories(:books_novels_genre).id],
        "excluded_category_ids" => [categories(:books_politics_subject).id],
        "included_country_ids" => [books_countries(:french).id, books_countries(:japanese).id],
        "excluded_country_ids" => [books_countries(:unknown).id],
        "included_language_ids" => [languages(:french).id],
        "excluded_language_ids" => [languages(:english).id],
        "book_length" => [1, 4],
        "first_year_published_gt" => 1800,
        "first_year_published_lt" => 1899,
        "ranked" => "true",
        "min_ranked_position" => 5,
        "max_ranked_position" => 50,
        "hide_read" => "true"
      }, result.criteria)
      assert_equal({
        category_id: "fiction,novels", category_match: "any", exclude_category_id: "politics",
        country_id: "french,japanese", exclude_country_id: "unknown",
        language: "french", exclude_language: "english", length: "short,long",
        published_start: 1800, published_end: 1899, ranked: "ranked",
        rank_min: 5, rank_max: 50, hide_read: true
      }, result.applied)
      assert_equal :rank, result.order
      assert_nil result.seed
    end

    test "no parameters gives the defaults only" do
      result = filter({})

      assert_equal({"genre_match_mode" => "all", "hide_read" => "false"}, result.criteria)
      assert_equal :rank, result.order
      assert_nil result.seed
      assert_empty result.applied
    end

    test "year sets both bounds and is applied as an integer" do
      result = filter(year: "1869")

      assert_equal [1869, 1869], result.criteria.values_at("first_year_published_gt", "first_year_published_lt")
      assert_equal({year: 1869}, result.applied)
    end

    test "unranked writes ranked false and all writes no ranked key" do
      assert_equal "false", filter(ranked: "unranked").criteria["ranked"]
      assert_not filter(ranked: "all").criteria.key?("ranked")
    end

    test "either rank bound implies ranked" do
      assert_equal "true", filter(rank_max: "10").criteria["ranked"]
      assert_equal "true", filter(rank_min: "10").criteria["ranked"]
    end

    test "hide_read false is accepted and not applied" do
      result = filter(hide_read: "false")

      assert_equal "false", result.criteria["hide_read"]
      assert_empty result.applied
    end

    test "order random without a seed picks one" do
      result = filter(order: "random")

      assert_equal :random, result.order
      assert_includes 1..2_147_483_647, result.seed
      assert_not result.applied.key?(:order)
      assert_not result.applied.key?(:seed)
    end

    test "order random with a seed keeps it" do
      assert_equal 42, filter(order: "random", seed: "42").seed
    end

    test "malformed or contradictory parameters are 400s naming the parameter" do
      assert_invalid({language: ""}, "language")
      assert_invalid({language: ["x"]}, "language")
      assert_invalid({language: (1..11).map { |i| "lang-#{i}" }.join(",")}, "language")
      assert_invalid({length: "huge"}, "length")
      assert_invalid({ranked: "maybe"}, "ranked")
      assert_invalid({order: "popular"}, "order")
      assert_invalid({category_match: "any"}, "category_match")
      assert_invalid({category_id: "fiction", category_match: "some"}, "category_match")
      assert_invalid({year: "1900", published_start: "1800"}, "year")
      assert_invalid({rank_min: "10", rank_max: "5"}, "rank_min")
      assert_invalid({rank_min: "0"}, "rank_min")
      assert_invalid({rank_max: "5", ranked: "unranked"}, "rank_max", "unranked")
      assert_invalid({seed: "5"}, "seed")
      assert_invalid({order: "random", seed: "0"}, "seed")
      assert_invalid({hide_read: "yes"}, "hide_read")
      assert_invalid({country_id: "french", exclude_country_id: "french"}, "country_id", "exclude_country_id")
      assert_invalid({language: "french", exclude_language: "french"}, "language", "exclude_language")
    end

    test "unknown slugs raise UnknownFilter under the API's own parameter name" do
      {language: "klingon", exclude_category_id: "nope", exclude_country_id: "nope", category_id: "nope", country_id: "nope"}.each do |name, slug|
        error = assert_raises(Api::UnknownFilter) { filter(name => slug) }
        assert_equal name.to_s, error.param
      end
    end

    test "too many exclude slugs name the exclude parameter" do
      assert_invalid({exclude_category_id: (1..7).map { |i| "c#{i}" }.join(",")}, "exclude_category_id")
    end

    test "a merged category slug in exclude_category_id excludes the merge target" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      assert_equal [target.id], filter(exclude_category_id: "france-country").criteria["excluded_category_ids"]
    end

    test "including a category target while excluding its merged slug is a 400" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      assert_invalid({category_id: "france", exclude_category_id: "france-country"}, "category_id", "exclude_category_id")
    end
  end
end
