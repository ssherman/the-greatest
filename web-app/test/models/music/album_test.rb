require "test_helper"

module Music
  class AlbumTest < ActiveSupport::TestCase
    def setup
      @album = music_albums(:dark_side_of_the_moon)
      @artist = music_artists(:pink_floyd)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @album.valid?
    end

    test "should require title" do
      @album.title = nil
      assert_not @album.valid?
      assert_includes @album.errors[:title], "can't be blank"
    end

    test "should require primary_artist" do
      @album.primary_artist = nil
      assert_not @album.valid?
      assert_includes @album.errors[:primary_artist], "can't be blank"
    end

    test "should allow description" do
      @album.description = "A classic album."
      assert @album.valid?
      assert_equal "A classic album.", @album.description
    end

    test "should allow empty description" do
      @album.description = nil
      assert @album.valid?
    end

    test "should allow nil release_year" do
      @album.release_year = nil
      assert @album.valid?
    end

    test "should require integer release_year if present" do
      @album.release_year = 1973
      assert @album.valid?
      @album.release_year = "not a year"
      assert_not @album.valid?
      assert_includes @album.errors[:release_year], "is not a number"
    end

    # Associations
    test "should belong to primary_artist" do
      assert_respond_to @album, :primary_artist
      assert_equal @artist, @album.primary_artist
    end

    # FriendlyId (basic integration)
    test "should find by slug" do
      found = Music::Album.friendly.find(@album.slug)
      assert_equal @album, found
    end
  end
end
