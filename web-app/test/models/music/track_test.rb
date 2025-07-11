# == Schema Information
#
# Table name: music_tracks
#
#  id            :bigint           not null, primary key
#  length_secs   :integer
#  medium_number :integer          default(1), not null
#  notes         :text
#  position      :integer          not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  release_id    :bigint           not null
#  song_id       :bigint           not null
#
# Indexes
#
#  index_music_tracks_on_release_id               (release_id)
#  index_music_tracks_on_release_medium_position  (release_id,medium_number,position) UNIQUE
#  index_music_tracks_on_song_id                  (song_id)
#
# Foreign Keys
#
#  fk_rails_...  (release_id => music_releases.id)
#  fk_rails_...  (song_id => music_songs.id)
#
require "test_helper"

module Music
  class TrackTest < ActiveSupport::TestCase
    def setup
      @track = music_tracks(:dark_side_original_1)
      @release = music_releases(:dark_side_original)
      @song = music_songs(:time)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @track.valid?
    end

    test "should require release" do
      @track.release = nil
      assert_not @track.valid?
      assert_includes @track.errors[:release], "must exist"
    end

    test "should require song" do
      @track.song = nil
      assert_not @track.valid?
      assert_includes @track.errors[:song], "must exist"
    end

    test "should require medium_number" do
      @track.medium_number = nil
      assert_not @track.valid?
      assert_includes @track.errors[:medium_number], "can't be blank"
    end

    test "should require positive medium_number" do
      @track.medium_number = 0
      assert_not @track.valid?
      assert_includes @track.errors[:medium_number], "must be greater than 0"
    end

    test "should require position" do
      @track.position = nil
      assert_not @track.valid?
      assert_includes @track.errors[:position], "can't be blank"
    end

    test "should require positive position" do
      @track.position = 0
      assert_not @track.valid?
      assert_includes @track.errors[:position], "must be greater than 0"
    end

    test "should allow nil length_secs" do
      @track.length_secs = nil
      assert @track.valid?
    end

    test "should require positive integer length_secs if present" do
      @track.length_secs = 421
      assert @track.valid?
      @track.length_secs = 0
      assert_not @track.valid?
      assert_includes @track.errors[:length_secs], "must be greater than 0"
      @track.length_secs = -1
      assert_not @track.valid?
      @track.length_secs = "not a number"
      assert_not @track.valid?
      assert_includes @track.errors[:length_secs], "is not a number"
    end

    # Associations
    test "should belong to release" do
      assert_respond_to @track, :release
      assert_equal @release, @track.release
    end

    test "should belong to song" do
      assert_respond_to @track, :song
      assert_equal @song, @track.song
    end

    # Scopes
    test "should order tracks by medium_number and position" do
      ordered = Music::Track.ordered
      assert ordered.first.medium_number <= ordered.last.medium_number
    end

    test "should filter tracks on a given medium" do
      tracks_on_1 = Music::Track.on_medium(1)
      assert tracks_on_1.all? { |t| t.medium_number == 1 }
    end
  end
end
