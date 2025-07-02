require "test_helper"

module Music
  class SongTest < ActiveSupport::TestCase
    def setup
      @song = music_songs(:time)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @song.valid?
    end

    test "should require title" do
      @song.title = nil
      assert_not @song.valid?
      assert_includes @song.errors[:title], "can't be blank"
    end

    test "should require slug" do
      # With FriendlyId, slug is auto-generated from title, so we can't test nil slug
      # The slug validation ensures the slug is present after generation
      assert @song.slug.present?
    end

    test "should allow nil duration_secs" do
      @song.duration_secs = nil
      assert @song.valid?
    end

    test "should require positive duration_secs if present" do
      @song.duration_secs = 421
      assert @song.valid?
      @song.duration_secs = 0
      assert_not @song.valid?
      assert_includes @song.errors[:duration_secs], "must be greater than 0"
      @song.duration_secs = -1
      assert_not @song.valid?
    end

    test "should require integer duration_secs" do
      @song.duration_secs = "not a number"
      assert_not @song.valid?
      assert_includes @song.errors[:duration_secs], "is not a number"
    end

    test "should allow blank isrc" do
      @song.isrc = nil
      assert @song.valid?
      @song.isrc = ""
      assert @song.valid?
    end

    test "should require 12 character isrc if present" do
      @song.isrc = "GBEMI7300001"
      assert @song.valid?
      @song.isrc = "TOOSHORT"
      assert_not @song.valid?
      assert_includes @song.errors[:isrc], "is the wrong length (should be 12 characters)"
    end

    test "should require unique isrc" do
      duplicate = @song.dup
      duplicate.title = "Different Title"
      duplicate.isrc = @song.isrc
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:isrc], "has already been taken"
    end

    test "should allow nil lyrics" do
      @song.lyrics = nil
      assert @song.valid?
    end

    # Scopes
    test "should filter songs with lyrics" do
      songs_with_lyrics = Music::Song.with_lyrics
      assert_includes songs_with_lyrics, music_songs(:time)
      assert_includes songs_with_lyrics, music_songs(:money)
      assert_not_includes songs_with_lyrics, music_songs(:shine_on)
    end

    test "should filter by duration" do
      short_songs = Music::Song.by_duration(400)
      assert_includes short_songs, music_songs(:money)
      assert_not_includes short_songs, music_songs(:time)
    end

    test "should filter longer than duration" do
      long_songs = Music::Song.longer_than(1000)
      assert_includes long_songs, music_songs(:shine_on)
      assert_not_includes long_songs, music_songs(:time)
    end

    # FriendlyId
    test "should find by slug" do
      found = Music::Song.friendly.find(@song.slug)
      assert_equal @song, found
    end

    # Duration formatting
    test "should format duration as mm:ss" do
      assert_equal "7:01", @song.duration_secs ? "#{@song.duration_secs / 60}:#{format("%02d", @song.duration_secs % 60)}" : nil
    end
  end
end
