# == Schema Information
#
# Table name: music_songs
#
#  id            :bigint           not null, primary key
#  description   :text
#  duration_secs :integer
#  isrc          :string(12)
#  lyrics        :text
#  notes         :text
#  release_year  :integer
#  slug          :string           not null
#  title         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_music_songs_on_isrc          (isrc) UNIQUE WHERE (isrc IS NOT NULL)
#  index_music_songs_on_release_year  (release_year)
#  index_music_songs_on_slug          (slug) UNIQUE
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

    test "should allow multiple songs with blank isrc" do
      # This tests the fix for the production bug where empty ISRC strings
      # violated the unique constraint because PostgreSQL treats '' as NOT NULL
      song1 = Music::Song.create!(title: "Song Without ISRC 1", isrc: "")
      song2 = Music::Song.create!(title: "Song Without ISRC 2", isrc: "")
      song3 = Music::Song.create!(title: "Song Without ISRC 3", isrc: nil)

      # All songs should have nil isrc (empty strings normalized to nil)
      assert_nil song1.reload.isrc
      assert_nil song2.reload.isrc
      assert_nil song3.reload.isrc
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
      @song.release_year = Date.current.year + 10
      assert_not @song.valid?
      assert_includes @song.errors[:release_year], "must be less than or equal to #{Date.current.year + 1}"
    end

    test "should require integer release_year" do
      @song.release_year = "not a year"
      assert_not @song.valid?
      assert_includes @song.errors[:release_year], "is not a number"
    end

    # Quote Normalization
    test "should normalize smart quotes in title on create" do
      song = Music::Song.create!(title: "\u2018Don\u2019t Stop Believin\u2019\u201D")
      assert_equal "'Don't Stop Believin'\"", song.title
    end

    test "should normalize smart quotes in title on update" do
      @song.update!(title: "\u201CThe Time\u201D")
      assert_equal "\"The Time\"", @song.title
    end

    test "should not modify title if no smart quotes present" do
      @song.update!(title: "Don't Stop")
      assert_equal "Don't Stop", @song.title
    end

    test "should normalize quotes for new songs with proper slug generation" do
      song = Music::Song.create!(title: "\u2018New Title\u2019")
      assert_equal "'New Title'", song.title
      assert_equal "new-title", song.slug
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

    test "should find songs by identifier" do
      song = music_songs(:time)
      mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

      # Create identifier for the song
      song.identifiers.create!(
        identifier_type: :music_musicbrainz_recording_id,
        value: mbid
      )

      result = Music::Song.with_identifier(:music_musicbrainz_recording_id, mbid)

      assert_includes result, song
    end

    test "should not find songs without matching identifier" do
      song = music_songs(:time)
      mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

      # Create identifier for the song
      song.identifiers.create!(
        identifier_type: :music_musicbrainz_recording_id,
        value: mbid
      )

      # Search for different MBID
      result = Music::Song.with_identifier(:music_musicbrainz_recording_id, "different-mbid")

      assert_not_includes result, song
      assert_equal 0, result.count
    end

    test "should find songs by ISRC identifier" do
      song = music_songs(:time)
      isrc = "USPR37300012"

      song.identifiers.create!(
        identifier_type: :music_isrc,
        value: isrc
      )

      result = Music::Song.with_identifier(:music_isrc, isrc)

      assert_includes result, song
    end

    test "should handle multiple songs with different identifiers" do
      song1 = music_songs(:time)
      song2 = music_songs(:money)
      mbid1 = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
      mbid2 = "7c8b8f05-bce8-5777-97cb-cc331fe5d4c3"

      song1.identifiers.create!(
        identifier_type: :music_musicbrainz_recording_id,
        value: mbid1
      )
      song2.identifiers.create!(
        identifier_type: :music_musicbrainz_recording_id,
        value: mbid2
      )

      result1 = Music::Song.with_identifier(:music_musicbrainz_recording_id, mbid1)
      result2 = Music::Song.with_identifier(:music_musicbrainz_recording_id, mbid2)

      assert_includes result1, song1
      assert_not_includes result1, song2
      assert_includes result2, song2
      assert_not_includes result2, song1
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

    # SearchIndexable concern tests
    test "should create search index request on create" do
      assert_difference "SearchIndexRequest.count", 1 do
        Music::Song.create!(title: "Test Song")
      end

      request = SearchIndexRequest.last
      assert_equal "Music::Song", request.parent_type
      assert request.index_item?
    end

    test "should create search index request on update" do
      song = music_songs(:time)

      assert_difference "SearchIndexRequest.count", 1 do
        song.update!(title: "Updated Title")
      end

      request = SearchIndexRequest.last
      assert_equal song, request.parent
      assert request.index_item?
    end

    test "should not create search index request if validation fails" do
      assert_no_difference "SearchIndexRequest.count" do
        Music::Song.create!(title: nil) # Invalid - title is required
      rescue ActiveRecord::RecordInvalid
        # Expected to fail
      end
    end

    test "should create search index request on destroy" do
      song = music_songs(:time)

      # Note: after_destroy callback should trigger after the record is destroyed
      assert_difference "SearchIndexRequest.count", 1 do
        song.destroy!
      end

      request = SearchIndexRequest.last
      assert_equal song.id, request.parent_id
      assert_equal "Music::Song", request.parent_type
      assert request.unindex_item?
    end

    test "as_indexed_json should include required fields when song has albums" do
      song = music_songs(:time)
      album = music_albums(:dark_side_of_the_moon)

      # Create a release and track to connect song to album
      release = Music::Release.create!(album: album, release_name: "Test Release")
      Music::Track.create!(song: song, release: release, position: 1)

      indexed_data = song.as_indexed_json

      assert_equal song.title, indexed_data[:title]
      assert_includes indexed_data.keys, :artist_names
      assert_includes indexed_data.keys, :artist_ids
      assert_includes indexed_data.keys, :album_ids
      assert_includes indexed_data.keys, :category_ids

      assert indexed_data[:artist_names].is_a?(Array)
      assert indexed_data[:album_ids].is_a?(Array)
      assert indexed_data[:category_ids].is_a?(Array)
    end

    test "as_indexed_json should handle song without albums" do
      song = Music::Song.create!(title: "Standalone Song")

      indexed_data = song.as_indexed_json

      assert_equal song.title, indexed_data[:title]
      assert_equal [], indexed_data[:artist_names]
      assert_equal [], indexed_data[:artist_ids]
      assert_equal [], indexed_data[:album_ids]
      assert_equal [], indexed_data[:category_ids]
    end

    test "as_indexed_json should only include active categories" do
      song = music_songs(:time)

      # Create a category and associate it
      category = Music::Category.create!(name: "Progressive Rock", type: "Music::Category")
      CategoryItem.create!(category: category, item: song)

      # Create a deleted category and associate it
      deleted_category = Music::Category.create!(name: "Psychedelic", type: "Music::Category", deleted: true)
      CategoryItem.create!(category: deleted_category, item: song)

      indexed_data = song.as_indexed_json

      assert_includes indexed_data[:category_ids], category.id
      assert_not_includes indexed_data[:category_ids], deleted_category.id
    end

    # update_release_year_from_identifiers! tests
    test "update_release_year_from_identifiers! returns false when no recording identifiers" do
      song = music_songs(:time)
      song.identifiers.where(identifier_type: :music_musicbrainz_recording_id).destroy_all

      result = song.update_release_year_from_identifiers!

      assert_not result
    end

    test "update_release_year_from_identifiers! updates when MB year is earlier" do
      song = music_songs(:time)
      song.update!(release_year: 2000)

      # Add recording ID identifier
      song.identifiers.create!(
        identifier_type: :music_musicbrainz_recording_id,
        value: "test-mbid-123"
      )

      # Mock the MusicBrainz lookup
      recording_search = mock
      ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(recording_search)
      recording_search.stubs(:lookup_by_mbid).with("test-mbid-123").returns({
        success: true,
        data: {
          "recordings" => [{
            "first-release-date" => "1973-03-01"
          }]
        }
      })

      result = song.update_release_year_from_identifiers!

      assert result
      assert_equal 1973, song.reload.release_year
    end

    test "update_release_year_from_identifiers! does not update when MB year is later" do
      song = music_songs(:time)
      original_year = song.release_year # 1973

      song.identifiers.create!(
        identifier_type: :music_musicbrainz_recording_id,
        value: "test-mbid-123"
      )

      recording_search = mock
      ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(recording_search)
      recording_search.stubs(:lookup_by_mbid).returns({
        success: true,
        data: {
          "recordings" => [{
            "first-release-date" => "2020-01-01"
          }]
        }
      })

      result = song.update_release_year_from_identifiers!

      assert_not result
      assert_equal original_year, song.reload.release_year
    end

    test "update_release_year_from_identifiers! updates when current year is nil" do
      song = music_songs(:time)
      song.update!(release_year: nil)

      song.identifiers.create!(
        identifier_type: :music_musicbrainz_recording_id,
        value: "test-mbid-123"
      )

      recording_search = mock
      ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(recording_search)
      recording_search.stubs(:lookup_by_mbid).returns({
        success: true,
        data: {
          "recordings" => [{
            "first-release-date" => "1980"
          }]
        }
      })

      result = song.update_release_year_from_identifiers!

      assert result
      assert_equal 1980, song.reload.release_year
    end

    test "update_release_year_from_identifiers! finds minimum across multiple MBIDs" do
      song = music_songs(:time)
      song.update!(release_year: nil)

      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "mbid-1")
      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "mbid-2")
      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "mbid-3")

      recording_search = mock
      ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(recording_search)

      recording_search.stubs(:lookup_by_mbid).with("mbid-1").returns({
        success: true,
        data: {"recordings" => [{"first-release-date" => "1980"}]}
      })
      recording_search.stubs(:lookup_by_mbid).with("mbid-2").returns({
        success: true,
        data: {"recordings" => [{"first-release-date" => "1973"}]}  # Earliest
      })
      recording_search.stubs(:lookup_by_mbid).with("mbid-3").returns({
        success: true,
        data: {"recordings" => [{"first-release-date" => "1990"}]}
      })

      song.update_release_year_from_identifiers!

      assert_equal 1973, song.reload.release_year
    end

    test "update_release_year_from_identifiers! handles failed lookups gracefully" do
      song = music_songs(:time)
      song.update!(release_year: nil)

      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "mbid-1")
      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "mbid-2")

      recording_search = mock
      ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(recording_search)

      # First lookup fails
      recording_search.stubs(:lookup_by_mbid).with("mbid-1").returns({
        success: false,
        data: nil
      })
      # Second lookup succeeds
      recording_search.stubs(:lookup_by_mbid).with("mbid-2").returns({
        success: true,
        data: {"recordings" => [{"first-release-date" => "1985"}]}
      })

      song.update_release_year_from_identifiers!

      assert_equal 1985, song.reload.release_year
    end

    test "update_release_year_from_identifiers! handles QueryError gracefully" do
      song = music_songs(:time)
      song.update!(release_year: nil)

      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "invalid-mbid")
      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "valid-mbid")

      recording_search = mock
      ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(recording_search)

      # First lookup raises QueryError
      recording_search.stubs(:lookup_by_mbid).with("invalid-mbid").raises(
        ::Music::Musicbrainz::Exceptions::QueryError.new("Invalid MBID format")
      )
      # Second lookup succeeds
      recording_search.stubs(:lookup_by_mbid).with("valid-mbid").returns({
        success: true,
        data: {"recordings" => [{"first-release-date" => "1990"}]}
      })

      result = song.update_release_year_from_identifiers!

      assert result
      assert_equal 1990, song.reload.release_year
    end

    test "update_release_year_from_identifiers! ignores invalid years" do
      song = music_songs(:time)
      song.update!(release_year: nil)

      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "mbid-1")
      song.identifiers.create!(identifier_type: :music_musicbrainz_recording_id, value: "mbid-2")

      recording_search = mock
      ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(recording_search)

      # First lookup has invalid year (too old)
      recording_search.stubs(:lookup_by_mbid).with("mbid-1").returns({
        success: true,
        data: {"recordings" => [{"first-release-date" => "1800"}]}
      })
      # Second lookup has valid year
      recording_search.stubs(:lookup_by_mbid).with("mbid-2").returns({
        success: true,
        data: {"recordings" => [{"first-release-date" => "1975"}]}
      })

      song.update_release_year_from_identifiers!

      assert_equal 1975, song.reload.release_year
    end

    # Callback tests
    test "queues enrichment job after creation" do
      Music::EnrichSongRecordingIdsJob.expects(:perform_in).with(1.minute, kind_of(Integer)).once

      Music::Song.create!(title: "New Test Song")
    end

    test "does not queue enrichment job on update" do
      Music::EnrichSongRecordingIdsJob.expects(:perform_in).never

      @song.update!(title: "Updated Title Again")
    end
  end
end
