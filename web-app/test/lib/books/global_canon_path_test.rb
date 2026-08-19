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

    private

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
