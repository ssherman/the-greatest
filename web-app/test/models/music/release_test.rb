# == Schema Information
#
# Table name: music_releases
#
#  id           :bigint           not null, primary key
#  country      :string
#  format       :integer          default("vinyl"), not null
#  labels       :string           default([]), is an Array
#  metadata     :jsonb
#  release_date :date
#  release_name :string
#  status       :integer          default("official"), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  album_id     :bigint           not null
#
# Indexes
#
#  index_music_releases_on_album_id  (album_id)
#  index_music_releases_on_country   (country)
#  index_music_releases_on_status    (status)
#
# Foreign Keys
#
#  fk_rails_...  (album_id => music_albums.id)
#
require "test_helper"

module Music
  class ReleaseTest < ActiveSupport::TestCase
    def setup
      @release = music_releases(:dark_side_original)
      @album = music_albums(:dark_side_of_the_moon)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @release.valid?
    end

    test "should require album" do
      @release.album = nil
      assert_not @release.valid?
      assert_includes @release.errors[:album], "must exist"
    end

    test "should require format" do
      @release.format = nil
      assert_not @release.valid?
      assert_includes @release.errors[:format], "can't be blank"
    end

    test "should allow nil release_name" do
      @release.release_name = nil
      assert @release.valid?
    end

    test "should allow nil release_date" do
      @release.release_date = nil
      assert @release.valid?
    end

    test "should allow nil metadata" do
      @release.metadata = nil
      assert @release.valid?
    end

    # Enums

    # Associations
    test "should belong to album" do
      assert_respond_to @release, :album
      assert_equal @album, @release.album
    end

    test "should have many tracks" do
      assert_respond_to @release, :tracks
      assert_includes @release.tracks, music_tracks(:dark_side_original_1)
      assert_includes @release.tracks, music_tracks(:dark_side_original_2)
    end

    test "should have many songs through tracks" do
      assert_respond_to @release, :songs
      assert_includes @release.songs, music_songs(:time)
      assert_includes @release.songs, music_songs(:money)
    end

    # Scopes
    test "should filter by format" do
      cd_releases = Music::Release.by_format(:cd)
      assert_includes cd_releases, music_releases(:dark_side_original)
      assert_includes cd_releases, music_releases(:dark_side_remaster)
    end

    test "should filter by release date" do
      releases_before_1974 = Music::Release.released_before(Date.new(1974, 1, 1))
      assert_includes releases_before_1974, music_releases(:dark_side_original)
      assert_not_includes releases_before_1974, music_releases(:dark_side_remaster)
    end

    # Metadata
    test "should access metadata values" do
      assert_equal "Harvest", @release.metadata["label"]
      assert_equal "SHVL 804", @release.metadata["catalog_number"]
      assert_equal "GB", @release.metadata["region"]
    end

    test "should update metadata" do
      @release.metadata["bonus_tracks"] = ["Eclipse (Live)"]
      @release.save!
      assert_includes @release.reload.metadata["bonus_tracks"], "Eclipse (Live)"
    end
  end
end
