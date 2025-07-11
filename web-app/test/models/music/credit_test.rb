# == Schema Information
#
# Table name: music_credits
#
#  id              :bigint           not null, primary key
#  creditable_type :string           not null
#  position        :integer
#  role            :integer          default("writer"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  artist_id       :bigint           not null
#  creditable_id   :bigint           not null
#
# Indexes
#
#  index_music_credits_on_artist_id                          (artist_id)
#  index_music_credits_on_artist_id_and_role                 (artist_id,role)
#  index_music_credits_on_creditable                         (creditable_type,creditable_id)
#  index_music_credits_on_creditable_type_and_creditable_id  (creditable_type,creditable_id)
#
# Foreign Keys
#
#  fk_rails_...  (artist_id => music_artists.id)
#
require "test_helper"

module Music
  class CreditTest < ActiveSupport::TestCase
    def setup
      @credit = music_credits(:time_writer)
      @artist = music_artists(:roger_waters)
      @song = music_songs(:time)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @credit.valid?
    end

    test "should require artist" do
      @credit.artist = nil
      assert_not @credit.valid?
      assert_includes @credit.errors[:artist], "must exist"
    end

    test "should require creditable" do
      @credit.creditable = nil
      assert_not @credit.valid?
      assert_includes @credit.errors[:creditable], "must exist"
    end

    test "should require role" do
      @credit.role = nil
      assert_not @credit.valid?
      assert_includes @credit.errors[:role], "can't be blank"
    end

    # Enums
    test "should have correct role enum values" do
      assert_equal 0, Music::Credit.roles[:writer]
      assert_equal 1, Music::Credit.roles[:composer]
      assert_equal 4, Music::Credit.roles[:performer]
      assert_equal 10, Music::Credit.roles[:producer]
      assert_equal 17, Music::Credit.roles[:sampler]
    end

    # Associations
    test "should belong to artist" do
      assert_respond_to @credit, :artist
      assert_equal @artist, @credit.artist
    end

    test "should belong to creditable" do
      assert_respond_to @credit, :creditable
      assert_equal @song, @credit.creditable
    end

    # Scopes
    test "should filter by role" do
      writers = Music::Credit.by_role(:writer)
      assert_includes writers, music_credits(:time_writer)
      assert_includes writers, music_credits(:money_writer)
      assert_not_includes writers, music_credits(:time_performer)
    end

    test "should filter for songs" do
      song_credits = Music::Credit.for_songs
      assert song_credits.all? { |c| c.creditable_type == "Music::Song" }
    end

    test "should filter for albums" do
      album_credits = Music::Credit.for_albums
      assert album_credits.all? { |c| c.creditable_type == "Music::Album" }
    end

    test "should filter for releases" do
      release_credits = Music::Credit.for_releases
      assert release_credits.all? { |c| c.creditable_type == "Music::Release" }
    end

    # Polymorphic behavior
    test "should work with different creditable types" do
      song_credit = music_credits(:time_writer)
      album_credit = music_credits(:dark_side_album_producer)
      release_credit = music_credits(:dark_side_release_engineer)

      assert song_credit.creditable.is_a?(Music::Song)
      assert album_credit.creditable.is_a?(Music::Album)
      assert release_credit.creditable.is_a?(Music::Release)
    end
  end
end
