require "test_helper"

module Books
  class GlobalCanonPathTest < ActiveSupport::TestCase
    test "returns the bare path for the defaults" do
      assert_equal "/global-canon", ::Books::GlobalCanonPath.call(settings)
    end

    test "varies total_books" do
      assert_equal "/global-canon/total_books/250/nonfiction/20/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(total_books: 250))
    end

    test "spells out a zero non-fiction share" do
      assert_equal "/global-canon/total_books/150/nonfiction/0/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(nonfiction_percentage: 0))
    end

    test "spells out a full non-fiction share" do
      assert_equal "/global-canon/total_books/150/nonfiction/100/max_per_country/3",
        ::Books::GlobalCanonPath.call(settings(nonfiction_percentage: 100))
    end

    test "varies max_books_per_country" do
      assert_equal "/global-canon/total_books/150/nonfiction/20/max_per_country/5",
        ::Books::GlobalCanonPath.call(settings(max_books_per_country: 5))
    end

    test "round-trip stability: path -> reparse -> path yields same path" do
      ::Books::GlobalCanonParams::TOTALS.each do |total|
        [0, 5, 20, 50, 100].each do |percentage|
          (1..10).each do |country_cap|
            # Step 1: Build params hash with these three values
            params1 = {
              total_books: total.to_s,
              nonfiction_percentage: percentage.to_s,
              max_books_per_country: country_cap.to_s
            }

            # Step 2: Parse params to settings
            settings1 = ::Books::GlobalCanonParams.call(params1)

            # Step 3: Generate path from settings
            path1 = ::Books::GlobalCanonPath.call(settings1)

            # Step 4: Extract the three segment values back out of path1
            if path1 == "/global-canon"
              # Bare path case: re-parsing means calling with empty params
              params2 = {}
            else
              # Extract the three segments from the path
              # Path format: /global-canon/total_books/{total}/nonfiction/{percentage}/max_per_country/{cap}
              match = path1.match(%r{\A/global-canon/total_books/(\d+)/nonfiction/(\d+)/max_per_country/(\d+)\z})
              refute match.nil?, "Path does not match expected format: #{path1}"

              params2 = {
                total_books: match[1],
                nonfiction_percentage: match[2],
                max_books_per_country: match[3]
              }
            end

            # Step 5: Parse extracted params to settings
            settings2 = ::Books::GlobalCanonParams.call(params2)

            # Step 6: Generate path from re-parsed settings
            path2 = ::Books::GlobalCanonPath.call(settings2)

            # Assert round-trip succeeds
            assert_equal path1, path2,
              "Round-trip failed for total_books=#{total}, nonfiction_percentage=#{percentage}, max_books_per_country=#{country_cap}: #{path1} != #{path2}"
          end
        end
      end
    end

    test "round-trip stability: excluded genres survive path -> reparse -> path" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      fantasy = ::Books::Category.create!(name: "Fantasy", slug: "fantasy", category_type: :genre)

      settings1 = ::Books::GlobalCanonParams.call(
        total_books: "250", excluded_genres: [fantasy.slug, poetry.slug]
      )
      path1 = ::Books::GlobalCanonPath.call(settings1)

      settings2 = ::Books::GlobalCanonParams.call(reparse(path1))
      path2 = ::Books::GlobalCanonPath.call(settings2)

      assert_equal path1, path2
    end

    test "round-trip stability: an unsorted excluded_genres param normalises, and the sorted form is then stable" do
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      ::Books::Category.create!(name: "Fantasy", slug: "fantasy", category_type: :genre)

      # Deliberately unsorted input: "poetry,fantasy", not "fantasy,poetry".
      settings1 = ::Books::GlobalCanonParams.call(excluded_genres: "poetry,fantasy")
      path1 = ::Books::GlobalCanonPath.call(settings1)

      assert_equal "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/fantasy,poetry",
        path1, "the first pass should already normalise to the sorted slug order"

      settings2 = ::Books::GlobalCanonParams.call(reparse(path1))
      path2 = ::Books::GlobalCanonPath.call(settings2)

      assert_equal path1, path2, "call(call(x)) must equal call(x) once normalised"
    end

    test "round-trip stability: defaults customised only by an excluded genre round-trips and never collapses to the bare path" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      # total_books, nonfiction_percentage and max_books_per_country are all at
      # their defaults here -- only the genre exclusion customises this canon.
      # This is the redirect-loop guard: if the `excluding` segment were ever
      # appended conditionally on `settings.default?` instead of on
      # `excluded_genres.empty?`, this path would come back bare, which would
      # then re-parse as `default?` and 301-loop against itself.
      settings1 = ::Books::GlobalCanonParams.call(excluded_genres: poetry.slug)
      path1 = ::Books::GlobalCanonPath.call(settings1)

      refute_equal "/global-canon", path1

      settings2 = ::Books::GlobalCanonParams.call(reparse(path1))
      path2 = ::Books::GlobalCanonPath.call(settings2)

      assert_equal path1, path2
    end

    test "appends excluded genres as comma-joined sorted slugs" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      fantasy = ::Books::Category.create!(name: "Fantasy", slug: "fantasy", category_type: :genre)

      assert_equal "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/fantasy,poetry",
        ::Books::GlobalCanonPath.call(settings(excluded_genres: [poetry, fantasy]))
    end

    test "the excluding segment only ever follows the full form" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      path = ::Books::GlobalCanonPath.call(settings(total_books: 250, excluded_genres: [poetry]))

      assert_match %r{\A/global-canon/total_books/250/nonfiction/20/max_per_country/3/excluding/poetry\z}, path
    end

    private

    # Extracts the params hash a controller would build from a path -- the
    # three required segments plus an optional trailing `/excluding/<slugs>`.
    def reparse(path)
      match = path.match(%r{\A/global-canon/total_books/(\d+)/nonfiction/(\d+)/max_per_country/(\d+)(?:/excluding/([a-z0-9,-]+))?\z})
      refute match.nil?, "Path does not match expected format: #{path}"

      params = {
        total_books: match[1],
        nonfiction_percentage: match[2],
        max_books_per_country: match[3]
      }
      params[:excluded_genres] = match[4] if match[4]
      params
    end

    def settings(total_books: 150, nonfiction_percentage: 20, max_books_per_country: 3, excluded_genres: [])
      ::Books::GlobalCanonParams::Settings.new(
        total_books: total_books,
        nonfiction_percentage: nonfiction_percentage,
        max_books_per_country: max_books_per_country,
        excluded_genres: excluded_genres
      )
    end
  end
end
