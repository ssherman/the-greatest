require "test_helper"

module Api
  class RankedBookFiltersTest < ActiveSupport::TestCase
    def filter(hash = {}, path_category: nil, **params)
      Api::RankedBookFilters.call(ActionController::Parameters.new(hash.merge(params)), path_category: path_category)
    end

    test "no filter params leaves everything empty" do
      result = filter({})

      assert_empty result.applied
      assert_empty result.categories
      assert_empty result.countries
      assert_nil result.year_start
      assert_nil result.year_end
      assert_nil result.collection
    end

    test "category_id comes back sorted in applied" do
      result = filter(category_id: "novels,fiction")

      assert_equal({category_id: "fiction,novels"}, result.applied)
      assert_equal %w[fiction novels], result.categories.map(&:slug)
    end

    test "repeated and empty slugs behave like the de-duplicated list" do
      messy = filter(category_id: "fiction,fiction,,novels")
      clean = filter(category_id: "fiction,novels")

      assert_equal clean.applied, messy.applied
      assert_equal clean.categories, messy.categories
    end

    test "a merged category slug comes back as the target's slug" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      assert_equal({category_id: "france"}, filter(category_id: "france-country").applied)
    end

    test "country_id comes back sorted in applied" do
      result = filter(country_id: "japanese,french")

      assert_equal({country_id: "french,japanese"}, result.applied)
      assert_equal %w[french japanese], result.countries.map(&:slug)
    end

    test "year sets both bounds and is applied as an integer" do
      result = filter(year: "1869")

      assert_equal "1869", result.year_start
      assert_equal "1869", result.year_end
      assert_equal({year: 1869}, result.applied)
    end

    test "a range is applied as two integers" do
      result = filter(published_start: "1800", published_end: "1899")

      assert_equal({published_start: 1800, published_end: 1899}, result.applied)
    end

    test "one end of a range is applied alone" do
      assert_equal({published_end: 1899}, filter(published_end: "1899").applied)
    end

    test "year with a range parameter is invalid" do
      error = assert_raises(Api::Page::InvalidParameter) { filter(year: "1869", published_start: "1800") }

      assert_includes error.message, "year"
    end

    test "a known collection is resolved and applied" do
      result = filter(collection: "women")

      assert_equal "women", result.collection.slug
      assert_equal({collection: "women"}, result.applied)
    end

    test "an unknown collection is invalid" do
      error = assert_raises(Api::Page::InvalidParameter) { filter(collection: "martians") }

      assert_includes error.message, "collection"
    end

    test "country_id with a collection is invalid and names both" do
      error = assert_raises(Api::Page::InvalidParameter) { filter(country_id: "french", collection: "women") }

      assert_includes error.message, "country_id"
      assert_includes error.message, "collection"
    end

    test "a blank value is invalid rather than unfiltered" do
      %w[category_id country_id year published_start published_end collection].each do |param|
        error = assert_raises(Api::Page::InvalidParameter, param) { filter(param => "") }

        assert_includes error.message, param
      end
    end

    test "a slug value of only separators is blank" do
      [",", ",,", " , "].each do |value|
        %w[category_id country_id].each do |param|
          error = assert_raises(Api::Page::InvalidParameter, "#{param}=#{value.inspect}") { filter(param => value) }

          assert_includes error.message, param
        end
      end
    end

    test "an array value is invalid and names the parameter" do
      error = assert_raises(Api::Page::InvalidParameter) { filter(category_id: ["fiction"]) }
      assert_includes error.message, "category_id"

      error = assert_raises(Api::Page::InvalidParameter) { filter(year: ["1869"]) }
      assert_includes error.message, "year"
    end

    test "a hash value is invalid and names the parameter" do
      error = assert_raises(Api::Page::InvalidParameter) { filter(country_id: {a: "french"}) }

      assert_includes error.message, "country_id"
    end

    test "more than six categories is invalid" do
      error = assert_raises(Api::Page::InvalidParameter) { filter(category_id: %w[a b c d e f g].join(",")) }

      assert_includes error.message, "category_id"
    end

    test "a malformed year is invalid" do
      error = assert_raises(Api::Page::InvalidParameter) { filter(year: "abc") }

      assert_includes error.message, "year"
    end

    test "an unknown category slug raises UnknownFilter naming the param and slug" do
      error = assert_raises(Api::UnknownFilter) { filter(category_id: "no-such-genre") }

      assert_includes error.message, "category_id"
      assert_includes error.message, "no-such-genre"
    end

    test "an unknown country slug raises UnknownFilter" do
      error = assert_raises(Api::UnknownFilter) { filter(country_id: "atlantean") }

      assert_includes error.message, "country_id"
      assert_includes error.message, "atlantean"
    end

    test "neither filter error is a RecordNotFound" do
      refute_operator Api::UnknownFilter, :<, ActiveRecord::RecordNotFound
      refute_operator Api::Page::InvalidParameter, :<, ActiveRecord::RecordNotFound
    end

    test "the path category counts toward the limit of six" do
      novels = categories(:books_novels_genre)

      assert_raises(Api::Page::InvalidParameter) do
        filter({category_id: %w[a b c d e f].join(",")}, path_category: novels)
      end
    end

    test "over the limit on the category path, the message says the path category counts" do
      novels = categories(:books_novels_genre)

      error = assert_raises(Api::Page::InvalidParameter) do
        filter({category_id: %w[a b c d e f].join(",")}, path_category: novels)
      end

      assert_equal "category_id: at most 6 categories, including the one in the path", error.message
    end

    test "over the limit without a path category, the message is the plain one" do
      error = assert_raises(Api::Page::InvalidParameter) { filter(category_id: %w[a b c d e f g].join(",")) }

      assert_equal "Invalid category_id: at most 6 values allowed", error.message
    end

    test "the path category is joined with category_id" do
      fiction = categories(:books_fiction_genre)
      novels = categories(:books_novels_genre)

      result = filter({category_id: "fiction"}, path_category: novels)

      assert_equal [fiction, novels], result.categories
      assert_equal({category_id: "fiction"}, result.applied)
    end

    test "category_id naming only the path category leaves applied without the key" do
      novels = categories(:books_novels_genre)

      result = filter({category_id: "novels"}, path_category: novels)

      assert_equal [novels], result.categories
      refute result.applied.key?(:category_id)
    end

    test "the path category alone is not an applied filter" do
      novels = categories(:books_novels_genre)

      result = filter({}, path_category: novels)

      assert_equal [novels], result.categories
      assert_empty result.applied
    end
  end
end
