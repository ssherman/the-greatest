require "test_helper"

module Books
  class FilterParamsTest < ActiveSupport::TestCase
    def resolve(hash)
      Books::FilterParams.call(ActionController::Parameters.new(hash))
    end

    test "no params resolves to empty filters" do
      result = resolve({})

      assert_empty result.categories
      assert_empty result.countries
      assert_nil result.year_start
      assert_nil result.year_end
    end

    test "resolves a single category slug" do
      result = resolve(category_id: "fiction")

      assert_equal [categories(:books_fiction_genre)], result.categories
    end

    test "resolves comma-joined category slugs sorted by slug" do
      result = resolve(category_id: "novels,fiction")

      assert_equal %w[fiction novels], result.categories.map(&:slug)
    end

    test "resolves comma-joined country slugs sorted by slug" do
      result = resolve(country_id: "japanese,french")

      assert_equal %w[french japanese], result.countries.map(&:slug)
    end

    test "raises on an unknown category slug" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(category_id: "no-such-genre")
      end
    end

    test "raises when only one of several category slugs is unknown" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(category_id: "fiction,no-such-genre")
      end
    end

    test "raises on a soft-deleted category slug" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(category_id: "retired-genre")
      end
    end

    test "raises on an unknown country slug" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(country_id: "atlantean")
      end
    end

    test "the year param sets both bounds" do
      result = resolve(year: "1984")

      assert_equal "1984", result.year_start
      assert_equal "1984", result.year_end
    end

    test "published_start and published_end map to the bounds" do
      result = resolve(published_start: "1900", published_end: "2000")

      assert_equal "1900", result.year_start
      assert_equal "2000", result.year_end
    end

    test "accepts a negative year for BC" do
      result = resolve(published_start: "-800")

      assert_equal "-800", result.year_start
    end

    test "raises on a non-integer year" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(published_start: "nineteen-eighty-four")
      end
    end

    test "ignores blank slug segments from a trailing comma" do
      result = resolve(category_id: "fiction,")

      assert_equal [categories(:books_fiction_genre)], result.categories
    end
  end
end
