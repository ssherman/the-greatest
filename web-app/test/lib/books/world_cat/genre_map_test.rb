require "test_helper"

module Books
  module WorldCat
    class GenreMapTest < ActiveSupport::TestCase
      setup { @map = GenreMap.load(file_fixture("worldcat_genre_map.yml")) }

      test "answers genre, subject and drop verdicts by exact term" do
        assert_equal "Fiction", @map.genre_for("Romans")
        assert_nil @map.genre_for("History")
        assert_equal "Politics", @map.subject_for("History")
        assert_nil @map.subject_for("Romans")
        assert_equal "format", @map.verdict("Large type books")["reason"]
        assert_nil @map.verdict("Unknown term")
        assert_nil @map.genre_for("fiction")  # exact match: folding is the pass's job
      end

      test "groups terms by genre and exposes the genre list" do
        assert_equal({"Fiction" => %w[Fiction Romans], "Novels" => ["novels"]}, @map.terms_by_genre)
        assert_equal ["Fiction", "Nonfiction", "Novels"], @map.genres
        assert_equal 6, @map.size
      end

      test "a missing file is an empty map" do
        map = GenreMap.load(Rails.root.join("tmp", "does-not-exist.yml"))
        assert_equal 0, map.size
        assert_nil map.genre_for("Fiction")
      end

      test "targets_for reads genre, audience, also and weak" do
        map = Books::WorldCat::GenreMap.new({
          "genres" => ["Science Fiction", "Fantasy"], "audiences" => ["Children's", "Young Adult"],
          "terms" => {
            "Fantasy och science fiction" => {"verdict" => "genre", "genre" => "Science Fiction", "also" => ["Fantasy"]},
            "Juvenile fiction" => {"verdict" => "audience", "audience" => "Children's", "weak" => true},
            "Young adult fiction" => {"verdict" => "audience", "audience" => "Young Adult"},
            "Electronic books" => {"verdict" => "drop", "reason" => "format"}
          }
        })

        assert_equal [[:genre, "Science Fiction", false], [:genre, "Fantasy", false]],
          map.targets_for("Fantasy och science fiction").map { |t| [t.kind, t.name, t.weak] }
        assert_equal [[:audience, "Children's", true]], map.targets_for("Juvenile fiction").map { |t| [t.kind, t.name, t.weak] }
        assert_empty map.targets_for("Electronic books")
        assert_equal({"Children's" => ["Juvenile fiction"], "Young Adult" => ["Young adult fiction"]}, map.terms_by_audience)
        assert_equal ["Children's", "Young Adult"], map.audiences
      end
    end
  end
end
