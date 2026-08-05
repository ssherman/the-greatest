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

    test "raises on a year magnitude beyond a 4-byte integer" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(published_start: "99999999999999999999")
      end
    end

    test "raises at the exact 4-byte integer boundary" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(published_start: "2147483648")
      end
    end

    test "normalizes a zero-padded year" do
      result = resolve(published_start: "0001900")

      assert_equal "1900", result.year_start
    end

    test "normalizes negative zero to zero" do
      result = resolve(published_start: "-0")

      assert_equal "0", result.year_start
    end

    test "normalizes a zero-padded negative year" do
      result = resolve(published_start: "-000800")

      assert_equal "-800", result.year_start
    end

    test "ignores blank slug segments from a trailing comma" do
      result = resolve(category_id: "fiction,")

      assert_equal [categories(:books_fiction_genre)], result.categories
    end

    test "deduplicates a repeated category slug" do
      result = resolve(category_id: "fiction,fiction")

      assert_equal [categories(:books_fiction_genre)], result.categories
    end

    test "raises on a slug belonging to another domain's category" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(category_id: "rock")
      end
    end

    test "raises on a category slug with the wrong casing" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(category_id: "FICTION")
      end
    end

    test "raises when published_start arrives array-shaped" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(published_start: ["1900"])
      end
    end

    test "raises when published_start arrives hash-shaped" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(published_start: {"a" => "b"})
      end
    end

    test "raises when year arrives array-shaped" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(year: ["1984"])
      end
    end

    test "raises when year arrives hash-shaped" do
      assert_raises ActiveRecord::RecordNotFound do
        resolve(year: {"a" => "b"})
      end
    end

    test "caps categories at MAX_CATEGORIES" do
      assert_equal 6, Books::FilterParams::MAX_CATEGORIES

      slugs = (1..7).map { |n|
        Books::Category.create!(name: "Generated Genre #{n}", category_type: :genre).slug
      }

      assert_nothing_raised do
        Books::FilterParams.call(ActionController::Parameters.new(category_id: slugs.first(6).join(",")))
      end

      assert_raises ActiveRecord::RecordNotFound do
        Books::FilterParams.call(ActionController::Parameters.new(category_id: slugs.join(",")))
      end
    end

    test "caps countries at MAX_COUNTRIES" do
      assert_equal 10, Books::FilterParams::MAX_COUNTRIES

      slugs = (1..11).map { |n|
        Books::Country.create!(name: "Generated Country #{n}").slug
      }

      assert_nothing_raised do
        Books::FilterParams.call(ActionController::Parameters.new(country_id: slugs.first(10).join(",")))
      end

      assert_raises ActiveRecord::RecordNotFound do
        Books::FilterParams.call(ActionController::Parameters.new(country_id: slugs.join(",")))
      end
    end

    test "the cap counts unique slugs, not repeats" do
      repeated = (["fiction"] * 20).join(",")

      assert_nothing_raised do
        Books::FilterParams.call(ActionController::Parameters.new(category_id: repeated))
      end
    end
  end
end
