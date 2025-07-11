# == Schema Information
#
# Table name: music_song_relationships
#
#  id                :bigint           not null, primary key
#  relation_type     :integer          default("cover"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  related_song_id   :bigint           not null
#  song_id           :bigint           not null
#  source_release_id :bigint
#
# Indexes
#
#  index_music_song_relationships_on_related_song_id    (related_song_id)
#  index_music_song_relationships_on_song_id            (song_id)
#  index_music_song_relationships_on_song_related_type  (song_id,related_song_id,relation_type) UNIQUE
#  index_music_song_relationships_on_source_release_id  (source_release_id)
#
# Foreign Keys
#
#  fk_rails_...  (related_song_id => music_songs.id)
#  fk_rails_...  (song_id => music_songs.id)
#  fk_rails_...  (source_release_id => music_releases.id)
#
require "test_helper"

module Music
  class SongRelationshipTest < ActiveSupport::TestCase
    def setup
      @cover = music_song_relationships(:wish_you_were_here_cover)
      @remix = music_song_relationships(:money_time_remix)
      @sample = music_song_relationships(:time_sample)
      @alternate = music_song_relationships(:shine_on_alternate)
      @song = music_songs(:wish_you_were_here)
      @related_song = music_songs(:shine_on)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @cover.valid?
    end

    test "should require song" do
      @cover.song = nil
      assert_not @cover.valid?
      assert_includes @cover.errors[:song], "must exist"
    end

    test "should require related_song" do
      @cover.related_song = nil
      assert_not @cover.valid?
      assert_includes @cover.errors[:related_song], "must exist"
    end

    test "should require relation_type" do
      @cover.relation_type = nil
      assert_not @cover.valid?
      assert_includes @cover.errors[:relation_type], "can't be blank"
    end

    test "should not allow self-reference" do
      @cover.related_song = @cover.song
      assert_not @cover.valid?
      assert_includes @cover.errors[:related_song_id], "cannot relate a song to itself"
    end

    test "should require unique relationship" do
      duplicate = @cover.dup
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:song_id], "relationship already exists"
    end

    # Enums
    test "should have correct relation_type enum values" do
      assert_equal 0, Music::SongRelationship.relation_types[:cover]
      assert_equal 1, Music::SongRelationship.relation_types[:remix]
      assert_equal 2, Music::SongRelationship.relation_types[:sample]
      assert_equal 3, Music::SongRelationship.relation_types[:alternate]
    end

    # Associations
    test "should belong to song" do
      assert_respond_to @cover, :song
      assert_equal @song, @cover.song
    end

    test "should belong to related_song" do
      assert_respond_to @cover, :related_song
      assert_equal @related_song, @cover.related_song
    end

    test "should belong to source_release (optional)" do
      assert_respond_to @cover, :source_release
      assert @cover.source_release.present?
    end

    # Scopes
    test "should filter covers" do
      covers = Music::SongRelationship.covers
      assert_includes covers, music_song_relationships(:wish_you_were_here_cover)
      assert_not_includes covers, music_song_relationships(:money_time_remix)
    end

    test "should filter remixes" do
      remixes = Music::SongRelationship.remixes
      assert_includes remixes, music_song_relationships(:money_time_remix)
      assert_not_includes remixes, music_song_relationships(:wish_you_were_here_cover)
    end

    # Song model helpers
    test "should return covers for a song" do
      song = music_songs(:wish_you_were_here)
      assert_includes song.covers, music_songs(:shine_on)
    end

    test "should return remixes for a song" do
      song = music_songs(:money)
      assert_includes song.remixes, music_songs(:time)
    end

    test "should return samples for a song" do
      song = music_songs(:time)
      assert_includes song.samples, music_songs(:money)
    end

    test "should return alternates for a song" do
      song = music_songs(:shine_on)
      assert_includes song.alternates, music_songs(:wish_you_were_here)
    end

    test "should return covered_by for a song" do
      song = music_songs(:shine_on)
      assert_includes song.covered_by, music_songs(:wish_you_were_here)
    end

    test "should return remixed_by for a song" do
      song = music_songs(:time)
      assert_includes song.remixed_by, music_songs(:money)
    end

    test "should return sampled_by for a song" do
      song = music_songs(:money)
      assert_includes song.sampled_by, music_songs(:time)
    end

    test "should return alternated_by for a song" do
      song = music_songs(:wish_you_were_here)
      assert_includes song.alternated_by, music_songs(:shine_on)
    end
  end
end
