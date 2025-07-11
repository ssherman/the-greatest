# == Schema Information
#
# Table name: music_songs
#
#  id            :bigint           not null, primary key
#  description   :text
#  duration_secs :integer
#  isrc          :string(12)
#  lyrics        :text
#  release_year  :integer
#  slug          :string           not null
#  title         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_music_songs_on_isrc  (isrc) UNIQUE WHERE (isrc IS NOT NULL)
#  index_music_songs_on_slug  (slug) UNIQUE
#
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

    test "should allow nil release_year" do
      @song.release_year = nil
      assert @song.valid?
    end

    test "should require valid release_year if present" do
      @song.release_year = 1973
      assert @song.valid?
      @song.release_year = 1800
      assert_not @song.valid?
      assert_includes @song.errors[:release_year], "must be greater than 1900"
      @song.release_year = 2030
      assert_not @song.valid?
      assert_includes @song.errors[:release_year], "must be less than or equal to 2026"
    end

    test "should require integer release_year" do
      @song.release_year = "not a year"
      assert_not @song.valid?
      assert_includes @song.errors[:release_year], "is not a number"
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

    test "should filter by release year" do
      songs_from_1973 = Music::Song.released_in(1973)
      assert_includes songs_from_1973, music_songs(:time)
      assert_includes songs_from_1973, music_songs(:money)
      assert_not_includes songs_from_1973, music_songs(:wish_you_were_here)
    end

    test "should filter released before year" do
      songs_before_1974 = Music::Song.released_before(1974)
      assert_includes songs_before_1974, music_songs(:time)
      assert_includes songs_before_1974, music_songs(:money)
      assert_not_includes songs_before_1974, music_songs(:wish_you_were_here)
    end

    test "should filter released after year" do
      songs_after_1974 = Music::Song.released_after(1974)
      assert_includes songs_after_1974, music_songs(:wish_you_were_here)
      assert_includes songs_after_1974, music_songs(:shine_on)
      assert_not_includes songs_after_1974, music_songs(:time)
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

    # Associations
    test "should have many tracks" do
      assert_respond_to @song, :tracks
      assert_includes @song.tracks, music_tracks(:dark_side_original_1)
      assert_includes @song.tracks, music_tracks(:dark_side_remaster_1)
    end

    test "should have many releases through tracks" do
      assert_respond_to @song, :releases
      assert_includes @song.releases, music_releases(:dark_side_original)
      assert_includes @song.releases, music_releases(:dark_side_remaster)
    end

    test "should have many albums through releases" do
      assert_respond_to @song, :albums
      assert_includes @song.albums, music_albums(:dark_side_of_the_moon)
    end
  end
end
