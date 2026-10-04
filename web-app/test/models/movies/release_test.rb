# == Schema Information
#
# Table name: movies_releases
#
#  id              :bigint           not null, primary key
#  is_primary      :boolean          default(FALSE), not null
#  metadata        :jsonb
#  release_date    :date
#  release_format  :integer          default("theatrical"), not null
#  release_name    :string
#  runtime_minutes :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  movie_id        :bigint           not null
#
# Indexes
#
#  index_movies_releases_on_is_primary                 (is_primary)
#  index_movies_releases_on_movie_and_name_and_format  (movie_id,release_name,release_format) UNIQUE
#  index_movies_releases_on_movie_id                   (movie_id)
#  index_movies_releases_on_release_date               (release_date)
#  index_movies_releases_on_release_format             (release_format)
#
# Foreign Keys
#
#  fk_rails_...  (movie_id => movies_movies.id)
#
require "test_helper"

module Movies
  class ReleaseTest < ActiveSupport::TestCase
    def setup
      @release = movies_releases(:godfather_theatrical)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @release.valid?
    end

    test "should require movie_id" do
      @release.movie_id = nil
      assert_not @release.valid?
      assert_includes @release.errors[:movie_id], "can't be blank"
    end

    test "should require release_format" do
      @release.release_format = nil
      assert_not @release.valid?
      assert_includes @release.errors[:release_format], "can't be blank"
    end

    test "should require is_primary to be true or false" do
      @release.is_primary = nil
      assert_not @release.valid?
      assert_includes @release.errors[:is_primary], "is not included in the list"
    end

    test "should validate uniqueness of release_name scoped to movie and release_format" do
      duplicate = @release.dup
      duplicate.release_name = @release.release_name
      duplicate.release_format = @release.release_format
      duplicate.movie_id = @release.movie_id
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:release_name], "should be unique per movie and format"
    end

    test "should allow nil release_name" do
      @release.release_name = nil
      assert @release.valid?
    end

    test "should validate runtime_minutes is positive integer" do
      @release.runtime_minutes = -10
      assert_not @release.valid?
      assert_includes @release.errors[:runtime_minutes], "must be greater than 0"
      @release.runtime_minutes = 120.5
      assert_not @release.valid?
      assert_includes @release.errors[:runtime_minutes], "must be an integer"
    end

    test "should allow nil runtime_minutes" do
      @release.runtime_minutes = nil
      assert @release.valid?
    end

    test "should validate release_date cannot be in the future" do
      @release.release_date = Date.current + 1.day
      assert_not @release.valid?
      assert_includes @release.errors[:release_date], "cannot be in the future"
    end

    # Enums
    test "should have correct release_format enum values" do
      assert_equal 0, Movies::Release.release_formats["theatrical"]
      assert_equal 1, Movies::Release.release_formats["dvd"]
      assert_equal 2, Movies::Release.release_formats["blu_ray"]
      assert_equal 3, Movies::Release.release_formats["digital"]
      assert_equal 4, Movies::Release.release_formats["vhs"]
      assert_equal 5, Movies::Release.release_formats["4k_blu_ray"]
    end

    # Associations
    test "should belong to movie" do
      assert_kind_of Movies::Movie, @release.movie
    end

    # Scopes
    test "primary scope should return only primary releases" do
      primaries = Movies::Release.primary
      assert_includes primaries, movies_releases(:godfather_theatrical)
      assert_not_includes primaries, movies_releases(:godfather_directors_cut)
    end

    test "by_release_format scope should filter by release_format" do
      theatrical = Movies::Release.by_release_format(:theatrical)
      assert_includes theatrical, movies_releases(:godfather_theatrical)
      assert_includes theatrical, movies_releases(:godfather_directors_cut)
    end

    test "recent scope should order by release_date desc" do
      releases = Movies::Release.recent
      assert releases.first.release_date >= releases.last.release_date
    end
  end
end
