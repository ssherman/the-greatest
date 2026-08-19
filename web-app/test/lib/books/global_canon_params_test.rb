require "test_helper"

module Books
  class GlobalCanonParamsTest < ActiveSupport::TestCase
    test "returns the defaults when no segments are given" do
      settings = Books::GlobalCanonParams.call({})

      assert_equal 150, settings.total_books
      assert_equal 20, settings.nonfiction_percentage
      assert_equal 3, settings.max_books_per_country
      assert_equal [], settings.excluded_genres
    end

    test "default? is true only for the exact default triple" do
      assert Books::GlobalCanonParams.call({}).default?
      refute Books::GlobalCanonParams.call(total_books: "250").default?
      refute Books::GlobalCanonParams.call(nonfiction_percentage: "0").default?
      refute Books::GlobalCanonParams.call(max_books_per_country: "1").default?
    end

    test "reads each setting from the params" do
      settings = Books::GlobalCanonParams.call(
        total_books: "250", nonfiction_percentage: "100", max_books_per_country: "1"
      )

      assert_equal 250, settings.total_books
      assert_equal 100, settings.nonfiction_percentage
      assert_equal 1, settings.max_books_per_country
    end

    test "accepts a non-fiction percentage the menu does not offer" do
      # The menu offers multiples of five; the route accepts any integer 0..100
      # so a hand-typed or bookmarked value still resolves.
      assert_equal 37, Books::GlobalCanonParams.call(nonfiction_percentage: "37").nonfiction_percentage
    end

    test "accepts both ends of the non-fiction range" do
      assert_equal 0, Books::GlobalCanonParams.call(nonfiction_percentage: "0").nonfiction_percentage
      assert_equal 100, Books::GlobalCanonParams.call(nonfiction_percentage: "100").nonfiction_percentage
    end

    test "404s on a total the menu does not offer" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(total_books: "175") }
    end

    test "404s on a percentage above 100" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(nonfiction_percentage: "101") }
    end

    test "404s on a country cap outside 1..10" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(max_books_per_country: "0") }
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(max_books_per_country: "11") }
    end

    test "404s on a non-numeric value" do
      assert_raises(ActiveRecord::RecordNotFound) { Books::GlobalCanonParams.call(total_books: "many") }
    end

    test "resolves excluded genre slugs from a comma-joined path segment" do
      poetry = genre("Poetry")
      fantasy = genre("Fantasy")

      settings = Books::GlobalCanonParams.call(excluded_genres: "poetry,fantasy")

      assert_equal [fantasy, poetry], settings.excluded_genres
    end

    test "resolves excluded genres from the form's array parameter" do
      poetry = genre("Poetry")

      settings = Books::GlobalCanonParams.call(excluded_genres: ["poetry"])

      assert_equal [poetry], settings.excluded_genres
    end

    test "sorts excluded genres by slug so one ordering is canonical" do
      genre("Poetry")
      genre("Fantasy")

      assert_equal %w[fantasy poetry],
        Books::GlobalCanonParams.call(excluded_genres: "poetry,fantasy").excluded_genres.map(&:slug)
    end

    test "404s on an unknown genre slug" do
      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: "not-a-genre")
      end
    end

    test "404s on a subject slug -- the picker is genres only" do
      subject = categories(:books_politics_subject)

      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: subject.slug)
      end
    end

    test "404s on a soft-deleted genre" do
      deleted = categories(:books_deleted_genre)

      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: deleted.slug)
      end
    end

    test "404s on more than the maximum number of exclusions" do
      slugs = (1..7).map { |i| genre("Genre #{i}").slug }

      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: slugs.join(","))
      end
    end

    test "default? is false once a genre is excluded" do
      genre("Poetry")

      refute Books::GlobalCanonParams.call(excluded_genres: "poetry").default?
    end

    private

    def genre(name)
      ::Books::Category.create!(name: name, slug: name.parameterize, category_type: :genre)
    end
  end
end
