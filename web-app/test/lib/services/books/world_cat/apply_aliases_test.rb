require "test_helper"

module Services
  module Books
    module WorldCat
      class ApplyAliasesTest < ActiveSupport::TestCase
        setup { @map = ::Books::WorldCat::GenreMap.load(file_fixture("worldcat_genre_map.yml")) }

        test "adds mapped terms as alternative names on the genre, skipping the genre's own name" do
          result = ApplyAliases.call(map: @map)
          assert result.success?
          assert_equal ["Romans"], categories(:books_fiction_genre).reload.alternative_names
          assert_equal ["novels"], categories(:books_novels_genre).reload.alternative_names
          assert_equal({categories_updated: 2, aliases_added: 2, missing_genres: []}, result.data)
        end

        test "is idempotent and reports a genre the map names that does not exist" do
          ApplyAliases.call(map: @map)
          categories(:books_fiction_genre).update!(alternative_names: ["Romans", "Kept"])
          result = ApplyAliases.call(map: @map)
          assert_equal ["Romans", "Kept"], categories(:books_fiction_genre).reload.alternative_names
          assert_equal 0, result.data[:aliases_added]

          map = ::Books::WorldCat::GenreMap.new({"genres" => ["Nope"], "terms" => {"X" => {"verdict" => "genre", "genre" => "Nope"}}})
          result = ApplyAliases.call(map: map)
          assert result.success?
          assert_equal ["Nope"], result.data[:missing_genres]
        end

        test "a name match is case-insensitive and ignores deleted categories" do
          categories(:books_fiction_genre).update!(name: "fiction")
          ApplyAliases.call(map: @map)
          assert_includes categories(:books_fiction_genre).reload.alternative_names, "Romans"
          assert_equal [], categories(:books_deleted_genre).reload.alternative_names
        end

        test "refuses an empty map and touches nothing" do
          result = ApplyAliases.call(map: ::Books::WorldCat::GenreMap.new({}))
          assert_not result.success?
          assert_match(/no terms/, result.errors.first)
          assert_equal [], categories(:books_fiction_genre).reload.alternative_names
        end

        test "audience terms become alternative names on the audience; a missing audience is reported" do
          ya = ::Books::Category.create!(name: "Young Adult", category_type: :audience)
          map = ::Books::WorldCat::GenreMap.new("audiences" => ["Young Adult", "Middle Grade"], "terms" => {
            "Young adult fiction" => {"verdict" => "audience", "audience" => "Young Adult"},
            "Middle grade fiction" => {"verdict" => "audience", "audience" => "Middle Grade"}
          })

          result = ApplyAliases.call(map: map)

          assert_includes ya.reload.alternative_names, "Young adult fiction"
          assert_includes result.data[:missing_genres], "Middle Grade"
        end
      end
    end
  end
end
