require "test_helper"

module Movies
  class MovieTest < ActiveSupport::TestCase
    def setup
      @movie = movies_movies(:godfather)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @movie.valid?
    end

    test "should require title" do
      @movie.title = nil
      assert_not @movie.valid?
      assert_includes @movie.errors[:title], "can't be blank"
    end

    test "should have unique slug" do
      duplicate_movie = @movie.dup
      duplicate_movie.title = @movie.title
      duplicate_movie.save!
      assert_not_equal @movie.slug, duplicate_movie.slug
      assert Movies::Movie.pluck(:slug).uniq.length == Movies::Movie.count
    end

    test "should validate release year is integer" do
      @movie.release_year = 1972.5
      assert_not @movie.valid?
      assert_includes @movie.errors[:release_year], "must be an integer"
    end

    test "should validate release year is reasonable" do
      @movie.release_year = 1800
      assert_not @movie.valid?
      assert_includes @movie.errors[:release_year], "must be greater than 1880"

      @movie.release_year = Date.current.year + 10
      assert_not @movie.valid?
      assert_includes @movie.errors[:release_year], "must be less than or equal to #{Date.current.year + 5}"
    end

    test "should allow nil release year" do
      @movie.release_year = nil
      assert @movie.valid?
    end

    test "should validate runtime minutes is positive integer" do
      @movie.runtime_minutes = -10
      assert_not @movie.valid?
      assert_includes @movie.errors[:runtime_minutes], "must be greater than 0"

      @movie.runtime_minutes = 175.5
      assert_not @movie.valid?
      assert_includes @movie.errors[:runtime_minutes], "must be an integer"
    end

    test "should allow nil runtime minutes" do
      @movie.runtime_minutes = nil
      assert @movie.valid?
    end

    # Enums
    test "should have correct rating enum values" do
      assert_equal 0, Movies::Movie.ratings["g"]
      assert_equal 1, Movies::Movie.ratings["pg"]
      assert_equal 2, Movies::Movie.ratings["pg_13"]
      assert_equal 3, Movies::Movie.ratings["r"]
      assert_equal 4, Movies::Movie.ratings["nc_17"]
      assert_equal 5, Movies::Movie.ratings["unrated"]
    end
  end
end
