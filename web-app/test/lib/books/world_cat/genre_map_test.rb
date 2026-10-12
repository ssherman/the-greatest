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
    end
  end
end
